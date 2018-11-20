Master/Slave Docker High Availability using etcd and haproxy
============================================================

MSDHA was written to run containers on top of Docker that traditionally support
a master/slave model where the master should accept connections while slaves
follow the master. The containers are split into a backend and frontend.

Data is stored in etcd under the /msdha prefix, followed by the group
(e.g.: /msdha/*my_msdha_group*). Locks are similarly stored under
/msdha_locks/*my_msdha_group*.

Variables
=========

The following environment variables are supported:

| Name              | Required      | Description |
|-------------------|---------------|-------------|
| ETCDCTL_ENDPOINTS | Yes           | A full URL to etcd including username and password if required |
| MSDHA_GROUP       | Yes           | The group/cluster that these containers will belong to |
| MSDHA_PORT        | Frontend only | The TCP port to forward traffic to on the master |
| MSHDA_NAME        | No            | The name of this node, defaults to hostname. Must resolve by DNS from the frontend container. |
| MSDHA_TTL         | No            | How often a node will refresh with etcd. This also determines how long a node will take to stop if it disconnects from etcd. |

Backend Container
=================

The backend is responsible for running your process. It maintains a lease with
etcd for its node key (`/msdha/my_msdha_group/my_node`). If the lease is lost for
whatever reason the backend is gracefully stopped after at most `MSDHA_TTL`
seconds. There are a few options for building a backend container.

Note: You MUST run MSDHA containers with the Docker `--init` flag.

You can use your own Docker container as a base for MSDHA by following this process:

  * Replace the file `backend/start_hook` with the script that will be used to
    start your main process. The main process MUST be started with `exec` so that
    it can receive signals.
  * Use this build command: `docker build backend --build-arg BASE_IMAGE=<your_image>`


You can also use MSDHA as a base for your own containers. MSDHA is built using
Alpine Linux.

    FROM msdha-backend

    # Rest of your Dockerfile
    ...

You can add MSDHA directly to your container. In this case you will need to:

  * Copy `run.sh` into your own container and make it the starting command,
    along with setting the environment variable `TINI_KILL_PROCESS_GROUP=1`
  * Provide a start hook at `/etc/msdha/hooks/start` that will start your main
    process under `exec`
  * Add etcdctl from https://github.com/coreos/etcd

The backend will run through the following states, calling a hook in
`/etc/msdha/hooks` for each state. A failure of any hook will cause the backend
container to terminate. The states are:

  1. pre_start
  1. start
  1. running_not_ready
  1. ready
  1. master

Pre_Start
---------

In this state the backend has not yet started the main process. This state is
useful for setting up configuration files, fetching any initial data and
performing any other tasks as required before the backend node starts your main
process.

Start
-----

In this state the backend will start the main process. You MUST provide a script
at `/etc/msdha/hooks/start` in order to start your main process and your script
MUST call `exec` in order to start your main process so that it can receive signals
correctly.

Running_Not_Ready
-----------------

In this state the backend has started but the main process may not yet be ready
to take over as master, or accept any other network connections as required.
If a hook script is provided, it should block until the node is ready and can
potentially be promoted to master.

Ready
-----

In this state the backend and main process are completely ready to be promoted to
master at any time. The backend will now attempt to take over the master lock.

Master
------

In this state the backend has been promoted to master by gaining the master lock
in etcd. Note that only one backend at a time can ever hold the lock. The
backend will wait **twice** the `MSDHA_TTL` value before running the hook script
for master promotion. The following scenario could happen, which is why the wait
has been added:

  1. The master node has lost connection to etcd and waits up to `MSDHA_TTL`
     before stopping the main process gracefully. This wait is due to the timeout
     when refreshing the node lease. This master node may still however be able
     to communicate with all other nodes while waiting for the timeout.
  1. The new master node takes over as master immediately while the old master
     is still running and able to communicate with other nodes, which could cause
     potential problems.

Note: A master is never demoted. It will always be terminated.

Other Backend Processes
=======================

The backend also has other processes that it runs. These processes are continuously
running while ever the backend is up. These processes start before the
`pre_start` state.

Node Lease Refresh
------------------

The backend node will have a key stored in etcd at `/msdha/my_msdha_group/node`
that contains the node state. The node will make sure the lease on this key is
continually refreshed. If the lease cannot be refreshed, the node will gracefully
terminate.

Node Change Detection
---------------------

The backend node can notify when any node (including itself) changes state. A hook
at `/etc/msdha/hooks/node_state_change` can be run whenever a node change occurs.
On startup, the hook will be called with the current list of nodes and their
current states. No de-duplication of state changes is performed.

Node change detection runs concurrently with all other hook scripts. This has the
benefit of being able to determine the current master and slaves during bring-up
of the backend, but can also cause issues if both the node change detection hook
and another hook are both trying to make changes. Synchronisation between these
hooks may be required.

The node change detection hook takes 3 arguments:

  1. The action:
      * `init`: The initial state of the mentioned node when this backend started
      * `PUT`: An add or update for a node
      * `DELETE`: The node has been removed
  1. The node name
  1. The node state (empty for DELETE)

The node change detection hook is run on every node change, but only one
invocation of the node change detection hook is run at a time. If a node rapidly
changes state (such as during start-up), the node change detection hook will be
run for each state change.

To assist with processing, the file `/run/msdha/is_master` will exist if this
backend is the current master node.

Frontend Container
==================

The frontend container simply exposes the current master. It listens for any
changes to the master and will begin sending traffic to the master node after
the hook script completes on the master node. You MUST run the frontend container
with the Docker `--init` flag. The frontend will send any TCP traffic it receives
on `MSDHA_PORT` to the master on `MSDHA_PORT`. No traffic is sent to slaves. You
can run multiple frontend containers for redundancy if required.

Note: The frontend connects to the backend master by name. If you change the name
of the backend by setting `MSDHA_NAME`, this name must resolve correctly to the
backend within Docker.

Best Practices and Pitfalls
===========================

The following is a list of areas where things could go wrong if you're not careful:

  * Do not use MSDHA outside of Docker. The spawned processes that handle things
    such as node lease refreshing will not be stopped, causing a backend node to
    still appear as available.
  * Make sure all containers are run with Docker's `--init` flag
  * Do not run the backend containers in the main Docker bridge or Docker swarm
    ingress networks. These networks do not support Docker's built-in DNS
    resolution and will result in the frontend not being able to resolve the
    master backend by name.
  * The frontend should be in the same network as the backend containers, but
    can be multi-homed across networks.
  * The node change detection hook runs concurrently with other hooks and may
    result in two hook scripts attempting to update a backend node at the same
    time. See the appropriate section for more detail.
  * If you set the backend container's hostname, you MUST set `MSDHA_NAME` to the
    container name. Docker's DNS will not resolve the hostname you set.
  * If a container looses connection to etcd, it will gracefully stop.
