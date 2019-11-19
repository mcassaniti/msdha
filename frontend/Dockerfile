FROM alpine

ENV TINI_KILL_PROCESS_GROUP=1
ENV ETCDCTL_API=3

# Add packages, user and sudo support
RUN apk --no-cache add haproxy curl sudo tini && \
  adduser -DHSg "MSHDA user" -h /dev/null msdha && \
  echo 'ALL ALL = (root) NOPASSWD: /setup.sh' > /etc/sudoers.d/setup

RUN etcd_release='3.4.3' && \
  wget -q "https://github.com/coreos/etcd/releases/download/v$etcd_release/etcd-v${etcd_release}-linux-amd64.tar.gz" -O /etcd.tar.gz && \
  tar -xf /etcd.tar.gz -C / && \
  mv /etcd*/etcdctl /usr/bin && \
  rm -rf /etcd* && \
  rm -f /etcd.tar.gz

USER msdha
COPY . /
CMD [ "/run.sh" ]
