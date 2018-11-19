FROM msdha-backend

ENV PGDATA=/var/lib/postgresql/data
VOLUME /var/lib/postgresql/data
RUN apk add --no-cache postgresql su-exec
ADD . /
