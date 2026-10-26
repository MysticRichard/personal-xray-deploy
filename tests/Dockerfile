FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    systemd systemd-sysv ca-certificates curl openssl unzip jq iproute2 procps \
    busybox python3-yaml shellcheck git && rm -rf /var/lib/apt/lists/*
ENV container=docker
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
