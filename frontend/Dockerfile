FROM alpine

ENV TINI_KILL_PROCESS_GROUP=1
RUN apk --no-cache add haproxy

RUN [ -x /sbin/apk ] && apk add --no-cache curl
# RUN latest_etcd_url="$(curl --silent --location https://api.github.com/repos/coreos/etcd/releases/latest | \
#     grep browser_download_url | \
#     grep linux-amd64.tar.gz\" | \
#     awk '{ print $2 }' | \
#     tr -d \")" && \
#   wget -q "$latest_etcd_url" -O /etcd.tar.gz && \
#   tar -xf /etcd.tar.gz -C / && \
#   mv /etcd*/etcdctl /usr/bin && \
#   rm -rf /etcd* && \
#   rm -f /etcd.tar.gz

RUN etcd_release='3.4.3' && \
  wget -q "https://github.com/coreos/etcd/releases/download/v$etcd_release/etcd-v${etcd_release}-linux-amd64.tar.gz" -O /etcd.tar.gz && \
  tar -xf /etcd.tar.gz -C / && \
  mv /etcd*/etcdctl /usr/bin && \
  rm -rf /etcd* && \
  rm -f /etcd.tar.gz

RUN ETCDCTL_API=3 etcdctl version

COPY . /
CMD [ "/run.sh" ]
