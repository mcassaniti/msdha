#!/bin/sh

MSDHA_STATE_DIR="/run/msdha"
MSDHA_TTL_DEFAULT=10
# This IP should be unreachable. haproxy needs an IP to start, so use this IP.
MSDHA_MASTER_DEFAULT="169.254.254.1"

do_error() {
  echo "MSDHA ERROR: $1"
  kill 1
  exit 1
}

check_inputs() {
  [ -z $ETCD_URL ]    && do_error "No etcd URL provided"
  [ -z $MSDHA_GROUP ] && do_error "No MSDHA group provided"
  [ -z $MSDHA_PORT ]  && do_error "No MSDH port provided"
}

node_change_detect_loop() {
  local current_rev="$($MSDHA_ETCD_CMD get msdha/$MSDHA_GROUP -w fields | grep Revision | awk -F ': ' '{ print $2 }')"

  ### Initial listing of nodes ###
  local line_item="node"
  local node=""

  $MSDHA_ETCD_CMD get --rev="$current_rev" --prefix "msdha/$MSDHA_GROUP" | while read line ; do
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
  $MSDHA_ETCD_CMD watch --rev="$current_rev" --prefix "msdha/$MSDHA_GROUP" | while read line ; do
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
  > /haproxy.cfg

  echo -n "$1" > "$MSDHA_STATE_DIR/current_master"
  [ -f /run/haproxy.pid ] && killall haproxy > /dev/null
  if [ -z $1 ] ; then
    echo "MSDHA: Backend removed and proxy stopped"
    rm -f /run/haproxy.pid
  else
    haproxy -f /haproxy.cfg -p /run/haproxy.pid
    echo "MSDHA: Backend now $1"
  fi
}

### Initialization ###
mkdir -p "$MSDHA_STATE_DIR"
check_inputs
export ETCDCTL_API=3
export MSDHA_TTL=${MSDHA_TTL:-$MSDHA_TTL_DEFAULT}
export MSDHA_ETCD_CMD="etcdctl --endpoints $ETCD_URL"

# Run background process and spawn background process
[ "$1" == "node_change_detect" ] && node_change_detect_loop
$0 "node_change_detect" &

### MAIN ###
echo "MSDHA: Attempting connection to etcd"
$MSDHA_ETCD_CMD get "msdha/$MSDHA_GROUP" > /dev/null
if [ $? -eq 0 ] ; then
  echo "MSDHA: Successful connection to etcd"
else
  exit 1
fi

node_lease="$($MSDHA_ETCD_CMD lease grant $MSDHA_TTL | awk '{ print $2 }')"

# Will block here
$MSDHA_ETCD_CMD lease keep-alive "$node_lease" > /dev/null

echo "MSDHA: Lost connection to etcd. Shutting down."
kill 1
