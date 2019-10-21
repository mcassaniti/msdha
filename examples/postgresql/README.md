PostgreSQL is capable of running a single master and multiple slave/standby
servers. The examples provided support this process.

Note: A base backup is required of PostgreSQL to get started. This will be stored
on the file system and needs to be bind mounted into every PostgreSQL backend
container at `/archives`. The example will not work unless a backup made with
`pg_basebackup --format tar --gzip` exists at `/archives/base/cur/`, including
both base and WAL archives.

The provided example configuration files use a combination of:

  * PostgreSQL base backups
  * PostgreSQL WAL archiving
  * PostgreSQL WAL streaming

The following environment variables will need to be set:

  * `PGSQL_RECOVERY_USER`: The name of PostgreSQL recovery user
  * `PGSQL_RECOVERY_PASS`: The password for the PostgreSQL recovery user
  * `PGSQL_FRONTEND_NAME`: The container name of the frontend container or docker swarm service

You will need to force the initial backend to become a master to bootstrap the
backend setup. To do so, make sure only 1 backend is running and create the file
`/archives/force_master`. Once the file is removed more backends can be added.
