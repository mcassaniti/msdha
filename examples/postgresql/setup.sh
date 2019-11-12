#!/bin/sh

mkdir -p /run/postgresql
chown postgres:postgres /run $PGDATA -R

su-exec postgres /run.sh
