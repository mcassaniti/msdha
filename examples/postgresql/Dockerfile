# The backend version is fixed so rebuilds can be properly controlled
FROM ghcr.io/mcassaniti/msdha-backend:2

ENV PGDATA=/var/lib/postgresql/data
VOLUME /var/lib/postgresql/data
RUN apk add --no-cache postgresql tar su-exec sudo
ADD . /

# Support non-root user by default
USER postgres

CMD /usr/bin/sudo -E /setup.sh
