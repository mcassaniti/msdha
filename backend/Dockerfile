ARG BASE_IMAGE=alpine
FROM $BASE_IMAGE
ARG ETCD_RELEASE=3.4.15

ENV TINI_KILL_PROCESS_GROUP=1
ENV ETCDCTL_API=3
RUN mkdir /etc/msdha/hooks -p

RUN wget -q "https://github.com/etcd-io/etcd/releases/download/v${ETCD_RELEASE}/etcd-v${ETCD_RELEASE}-linux-amd64.tar.gz" -O /etcd.tar.gz && \
  tar -xf /etcd.tar.gz -C / && \
  mv /etcd*/etcdctl /usr/bin && \
  rm -rf /etcd* && \
  rm -f /etcd.tar.gz

COPY run.sh /
COPY start_hook /etc/msdha/hooks/start
CMD ["/run.sh"]
