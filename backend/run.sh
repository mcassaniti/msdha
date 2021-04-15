#!/bin/sh

MSDHA_TTL_DEFAULT=10
MSDHA_MASTER_TTL_DEFAULT=1d
MSDHA_STATE_DIR="/run/msdha"

do_error() {
  echo "MSDHA ERROR: $1"
  kill 1
  exit 1
}

check_inputs() {
  [ -z $ETCDCTL_ENDPOINTS ] && do_error "No etcd URL provided"
  [ -z $MSDHA_GROUP ]       && do_error "No MSDHA group provided"
}

etcd_set_state() {
  local node_lease="$(cat $MSDHA_STATE_DIR/node_lease)"
  etcdctl put --lease="$node_lease" \
    "msdha/$MSDHA_GROUP/$MSDHA_NAME" \
    "$1" \
    > /dev/null

  [ $? -ne 0 ] && do_error "Failed to put state $1"

}

run_hook() {
  if [ -x /etc/msdha/hooks/"$1" ] ; then
    /etc/msdha/hooks/"$1" || do_error "Hook $1 failed"
  fi
}

lease_refresh() {
  local node_lease="$(etcdctl lease grant $MSDHA_TTL | awk '{ print $2 }')"
  echo -n "$node_lease" > "$MSDHA_STATE_DIR/node_lease"

  # Will block here
  etcdctl lease keep-alive "$node_lease" > /dev/null

  echo "MSDHA: Lost connection to etcd. Shutting down."
  kill 1
}

wait_master() {
  # Wait until the initial load of the state of all nodes
  while [ -f "$MSDHA_STATE_DIR/disable_master" ] ; do
    sleep 1
  done

  if [ -z "$(cat $MSDHA_STATE_DIR/current_master)" ] ; then
    # There is no master at initial startup so try to become master
    try_promote &
  fi
}

watcher() {
  etcdctl watch --rev="$1" --prefix "msdha/$MSDHA_GROUP" > "$MSDHA_STATE_DIR/watch_fifo"
}

change_detect() {
  touch "$MSDHA_STATE_DIR/current_master"
  local current_rev=""

  current_rev="$(etcdctl get msdha/$MSDHA_GROUP -w fields | grep Revision | awk -F ': ' '{ print $2 }')"

  ### Initial listing of nodes ###
  local line_item="node"
  local node=""
  local ignore=""

  etcdctl get --rev="$current_rev" --prefix "msdha/$MSDHA_GROUP" | while read line ; do
    case "$line_item" in
      "node")
        node="$(basename $line)"
        line_item="state"
        if [ $(basename $(dirname "$line") ) = "_promote_lock" ] ; then
          # Do not process the _promote_lock
          ignore="yes"
        fi
        ;;
      "state")
        if [ -z "$ignore" ] ; then
          [ -x /etc/msdha/hooks/node_state_change ] && /etc/msdha/hooks/node_state_change "init" "$node" "$line"
          line_item="node"

          if [ "x$line" = "xmaster" ] ; then
            echo -n "$node" > "$MSDHA_STATE_DIR/current_master"
          fi
        else
          ignore=""
        fi
        ;;
    esac
  done

  # Allow any attempts to become master at initial startup
  rm "$MSDHA_STATE_DIR/disable_master"

  while (true) ; do
    # A fifo and separate process is required so that a sub-shell is not used.
    # It's a bit ugly but it works.
    [ -p "$MSDHA_STATE_DIR/watch_fifo" ] && rm "$MSDHA_STATE_DIR/watch_fifo"
    mkfifo "$MSDHA_STATE_DIR/watch_fifo"

    ### Node changes ###
    local line_item="action"
    local action=""
    local node=""
    local ignore=""
    $0 watcher $current_rev &

    # Should be 'stuck' in this loop
    while read -r line ; do
      case "$line_item" in
        "action")
          action="$line"
          line_item="node"
          ;;
        "node")
          node="$(basename $line)"
          line_item="state"
          if [ $(basename $(dirname "$line") ) = "_promote_lock" ] ; then
            # Do not process the _promote_lock
            ignore="yes"
          fi
          ;;
        "state")
          line_item="action"
          # Record the revision again in case the watch is dropped
          current_rev="$(etcdctl get msdha/$MSDHA_GROUP -w fields | grep Revision | awk -F ': ' '{ print $2 }')"

          if [ -z "$ignore" ] ; then
            [ -x /etc/msdha/hooks/node_state_change ] && /etc/msdha/hooks/node_state_change "$action" "$node" "$line"

            # Update current master
            if [ "x$node" = "x$(cat "$MSDHA_STATE_DIR/current_master")" ] ; then
              if [ "x$action" = "xDELETE" ] ; then
                echo -n > "$MSDHA_STATE_DIR/current_master"

                # Master dropped so attempt promotion
                try_promote &
              fi
            elif [ "x$line" = "xmaster" ] ; then
              echo -n "$node" > "$MSDHA_STATE_DIR/current_master"
            fi
          else
            ignore=""
          fi
          ;;
      esac
    done < "$MSDHA_STATE_DIR/watch_fifo"

    # Exited, probably due to a etcd leader loss. Sleep and try again.
    sleep 1
  done
}

try_promote() {
  # Promote under a lock
  if [ ! -f "$MSDHA_STATE_DIR/disable_master" ] ; then
    let wait=${MSDHA_TTL}*2
    echo "MSDHA: Master lost. Waiting $wait seconds before attempting promotion."
    sleep $wait
    exec etcdctl lock --ttl ${MSDHA_TTL} "msdha/${MSDHA_GROUP}/_promote_lock" $0 promote
  fi
}

promote () {
  # Wait in case another node has already been promoted. This will allow the
  # node change detection to write the node out.
  sleep 2

  if [ -z "$(cat $MSDHA_STATE_DIR/current_master)" ] ; then
    # There is no master node
    echo -n "$MSDHA_NAME" > "$MSDHA_STATE_DIR/current_master"
    touch "$MSDHA_STATE_DIR/is_master"
    run_hook "master"
    echo "MSDHA: $MSDHA_NAME is now master"
    etcd_set_state "master"

    $0 promote_timeout &
  fi
}

promote_timeout() {
  # Remain promoted for this long
  sleep ${MSDHA_MASTER_TTL:-$MSDHA_MASTER_TTL_DEFAULT}
  echo "MSDHA: Exceeded master timeout. Stopping."

  # Prevent becoming a master during shutdown
  touch "$MSDHA_STATE_DIR/disable_master"

  kill 1
  exit 0
}

startup() {
  $0 "lease_refresh" &
  $0 "change_detect" &

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

  $0 "wait_master" &
}

### Initialization ###
check_inputs
export ETCDCTL_API=3
export MSDHA_NAME=${MSDHA_NAME:-$HOSTNAME}
export MSDHA_TTL=${MSDHA_TTL:-$MSDHA_TTL_DEFAULT}

# Run these tasks if spawned as another process
case "$1" in
  "startup")         startup         ; exit $?;;
  "lease_refresh")   lease_refresh   ; exit $?;;
  "change_detect")   change_detect   ; exit $?;;
  "wait_master")     wait_master     ; exit $?;;
  "try_promote")     try_promote     ; exit $?;;
  "promote")         promote         ; exit $?;;
  "promote_timeout") promote_timeout ; exit $?;;
  "watcher")         watcher $2      ; exit $?;;
  "*") ;;
esac

### MAIN ###
mkdir "$MSDHA_STATE_DIR"
echo "MSDHA: Attempting connection to etcd"
etcdctl get "msdha/$MSDHA_GROUP" > /dev/null
if [ $? -eq 0 ] ; then
  echo "MSDHA: Successful connection to etcd"
else
  exit 1
fi

# Disable initial master promotion until initial etcd records are read
# Promotion to master still needs to wait until this node is in the ready state
touch "$MSDHA_STATE_DIR/disable_master"

# Stop the main process from starting and start the startup process
touch "$MSDHA_STATE_DIR/start_wait"
$0 startup &

while [ -f "$MSDHA_STATE_DIR/start_wait" ] ; do
  sleep 1
done

if [ -x /etc/msdha/hooks/start ] ; then
  exec /etc/msdha/hooks/start
else
  do_error "No start script found"
fi
