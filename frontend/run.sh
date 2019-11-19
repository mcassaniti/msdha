#!/bin/sh

MSDHA_STATE_DIR="/run/msdha"
MSDHA_TTL_DEFAULT=10

do_error() {
  echo "MSDHA ERROR: $1"
  kill 1
  exit 1
}

check_inputs() {
  [ -z $ETCDCTL_ENDPOINTS ] && do_error "No etcd URL provided"
  [ -z $MSDHA_GROUP ]       && do_error "No MSDHA group provided"
  [ -z $MSDHA_PORT ]        && do_error "No MSDHA port provided"
}

node_change_detect_loop() {
  local current_rev="$(etcdctl get msdha/$MSDHA_GROUP -w fields | grep Revision | awk -F ': ' '{ print $2 }')"
  touch "$MSDHA_STATE_DIR/current_master"

  ### Initial listing of nodes ###
  local line_item="node"
  local node=""

  etcdctl get --rev="$current_rev" --prefix "msdha/$MSDHA_GROUP" | while read line ; do
    case "$line_item" in
      "node")
        node="$(basename $line)"
        line_item="state"
        ;;
      "state")
        [ "$line" = "master" ] && update_master "$node"
        line_item="node"
        ;;
    esac
  done

  ### Node changes ###
  local line_item="action"
  local action=""
  local node=""

  # Should be 'stuck' in this loop
  etcdctl watch --rev="$current_rev" --prefix "msdha/$MSDHA_GROUP" | while read line ; do
    case "$line_item" in
      "action")
        action="$line"
        line_item="node"
        ;;
      "node")
        node="$(basename $line)"
        line_item="state"
        ;;
      "state")
        line_item="action"

        # Master has changed
        [ "$line" = "master" -a "$(cat "$MSDHA_STATE_DIR/current_master")" != "$node" ] && update_master "$node"

        # Master removed
        [ -z "$line" -a "$(cat "$MSDHA_STATE_DIR/current_master")" = "$node" ] && update_master

        ;;
    esac
  done

  do_error "Lost connection to etcd"
}

update_master() {
  cat /haproxy.cfg.tmpl | \
  sed s/'BACKEND_MASTER'/"$1"/ | \
  sed s/'BACKEND_PORT'/"$MSDHA_PORT"/ \
  > /run/haproxy.cfg

  echo -n "$1" > "$MSDHA_STATE_DIR/current_master"
  [ -f /run/haproxy.pid ] && killall haproxy > /dev/null
  if [ -z $1 ] ; then
    echo "MSDHA: Backend removed and proxy stopped"
    rm -f /run/haproxy.pid
  else
    haproxy -f /run/haproxy.cfg -p /run/haproxy.pid
    echo "MSDHA: Backend now $1"
  fi
}

### Initialization ###

# Run under an init process
[ $$ -eq 1 ] && exec /sbin/tini $0
sudo /setup.sh $MSDHA_STATE_DIR
check_inputs
export MSDHA_TTL=${MSDHA_TTL:-$MSDHA_TTL_DEFAULT}

# Run background process and spawn background process
[ "$1" == "node_change_detect" ] && node_change_detect_loop
$0 "node_change_detect" &

### MAIN ###
echo "MSDHA: Attempting connection to etcd"
etcdctl get "msdha/$MSDHA_GROUP" > /dev/null
if [ $? -eq 0 ] ; then
  echo "MSDHA: Successful connection to etcd"
else
  exit 1
fi

# Get a lease
node_lease="$(etcdctl lease grant $MSDHA_TTL | awk '{ print $2 }')"

# Will block here keeping lease alive
etcdctl lease keep-alive "$node_lease" > /dev/null

echo "MSDHA: Lost connection to etcd. Shutting down."
kill 1
