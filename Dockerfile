FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd tini inotify-tools \
      iproute2 wireguard-tools \
      procps ca-certificates tcpdump bind9-dnsutils curl mtr-tiny \
 && rm -rf /var/lib/apt/lists/*

COPY rootfs/ /

RUN chmod +x /usr/local/sbin/netgw-entrypoint.sh /usr/local/sbin/netgw-watch /usr/local/sbin/netgw-lib.sh \
 && mkdir -p /run/netgw \
 && chmod 700 /etc/systemd/network-secrets

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/netgw-entrypoint.sh"]
