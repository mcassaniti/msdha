#!/bin/sh

# This script will set permissions on the state directory at runtime.
# /run will need to be mounted as a tmpfs volume if the container is set read-only.

mkdir -p $1
chown msdha:nogroup /run -R
