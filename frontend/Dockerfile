FROM alpine
ARG ETCD_RELEASE=3.4.15

ENV TINI_KILL_PROCESS_GROUP=1
ENV ETCDCTL_API=3

# Add packages, user and sudo support
RUN apk --no-cache add haproxy curl sudo tini && \
  adduser -DHSg "MSHDA user" -h /dev/null msdha && \
  echo 'ALL ALL = (root) NOPASSWD: /setup.sh' > /etc/sudoers.d/setup

RUN wget -q "https://github.com/etcd-io/etcd/releases/download/v${ETCD_RELEASE}/etcd-v${ETCD_RELEASE}-linux-amd64.tar.gz" -O /etcd.tar.gz && \
  tar -xf /etcd.tar.gz -C / && \
  mv /etcd*/etcdctl /usr/bin && \
  rm -rf /etcd* && \
  rm -f /etcd.tar.gz

USER msdha
COPY . /
CMD [ "/run.sh" ]
