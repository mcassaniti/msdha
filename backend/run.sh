#!/bin/sh

MSDHA_TTL_DEFAULT=10
MSDHA_STATE_DIR="/run/msdha"

do_error() {
  echo "MSDHA ERROR: $1"
  kill 1
  exit 1
}

check_inputs() {
  [ -z $ETCD_URL ]    && do_error "No etcd URL provided"
  [ -z $MSDHA_GROUP ] && do_error "No MSDHA group provided"
}

etcd_set_state() {
  local node_lease="$(cat $MSDHA_STATE_DIR/node_lease)"
  $MSDHA_ETCD_CMD put --lease="$node_lease" \
    "msdha/$MSDHA_GROUP/$MSDHA_NAME" \
    "$1" \
    > /dev/null

  [ $? -ne 0 ] && do_error "Failed to put state $1"

}

run_hook() {
  if [ -x /etc/msdha/hooks/"$1" ] ; then
    /etc/msdha/hooks/"$1" || do_error "MSDHA: Hook $1 failed"
  fi
}

node_lease_refresh_loop() {
  local node_lease="$($MSDHA_ETCD_CMD lease grant $MSDHA_TTL | awk '{ print $2 }')"
  echo -n "$node_lease" > "$MSDHA_STATE_DIR/node_lease"

  # Will block here
  $MSDHA_ETCD_CMD lease keep-alive "$node_lease" > /dev/null

  echo "MSDHA: Lost connection to etcd. Shutting down."
  kill 1
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
        [ -x /etc/msdha/hooks/node_state_change ] && /etc/msdha/hooks/node_state_change "init" "$node" "$line"
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
        [ -x /etc/msdha/hooks/node_state_change ] && /etc/msdha/hooks/node_state_change "$action" "$node" "$line"
        line_item="action"
        ;;
    esac
  done
}

master_loop() {
  let wait=${MSDHA_TTL}*2

  echo "MSDHA: Got master lock. Waiting $wait seconds before taking over as master."
  sleep $wait
  touch "$MSDHA_STATE_DIR/is_master"
  run_hook "master"
  echo "MSDHA: $MSDHA_NAME is now master"
  etcd_set_state "master"

  while(true) ; do
    # Essentially do nothing and keep holding the lock
    sleep 1d
  done

  echo "MSDHA: Stopped master loop"
}

do_main_background() {
  $0 "node_change_detect" &
  $0 "node_lease_refresh" &
  # This pause will make sure we have a lease
  sleep 1

  for state in pre_start start running_not_ready ready ; do
    echo "MSDHA: state is $state"
    if [ "$state" = "start" ] ; then
      rm "$MSDHA_STATE_DIR/start_wait"
    else
      run_hook "$state"
    fi
    etcd_set_state "$state"
  done

  # This should block trying to become a master
  exec $MSDHA_ETCD_CMD lock "msdha_locks/${MSDHA_GROUP}" $0 "master"
}

### Initialization ###
check_inputs
export ETCDCTL_API=3
export MSDHA_NAME=${MSDHA_NAME:-$HOSTNAME}
export MSDHA_ETCD_CMD="etcdctl --endpoints $ETCD_URL"
export MSDHA_TTL=${MSDHA_TTL:-$MSDHA_TTL_DEFAULT}

# Run these tasks if spawned as another process
case "$1" in
  "main_background")    do_main_background      ; exit $?;;
  "node_lease_refresh") node_lease_refresh_loop ; exit $?;;
  "node_change_detect") node_change_detect_loop ; exit $?;;
  "master")             master_loop ; exit $?;;
  "*") ;;
esac

### MAIN ###
mkdir "$MSDHA_STATE_DIR"
echo "MSDHA: Attempting connection to etcd"
$MSDHA_ETCD_CMD get "msdha/$MSDHA_GROUP" > /dev/null
if [ $? -eq 0 ] ; then
  echo "MSDHA: Successful connection to etcd"
else
  exit 1
fi

# Stop the main process from starting and start the main background process
touch "$MSDHA_STATE_DIR/start_wait"
$0 main_background &

while [ -f "$MSDHA_STATE_DIR/start_wait" ] ; do
  sleep 1
done

if [ -x /etc/msdha/hooks/start ] ; then
  exec /etc/msdha/hooks/start
else
  do_error "No start script found"
fi
