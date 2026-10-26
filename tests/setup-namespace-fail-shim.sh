#!/bin/sh
# Verify a host that rejects mount namespacing still ends up with a working
# subscription service via the minimal fallback unit.
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends python3-yaml jq busybox curl >/dev/null 2>&1
mkdir -p /test-shims2
cat > /test-shims2/systemctl <<'EOF'
#!/usr/bin/env bash
set -u
unit=${*: -1}
case $1 in
  is-active)
    case $unit in
      xray-sub) [[ -f /run/t2-sub.pid ]] && kill -0 "$(cat /run/t2-sub.pid)" 2>/dev/null;;
      *) exit 3;;
    esac;;
  restart|start)
    if [[ $unit == xray-sub ]]; then
      # First attempt fails exactly like the real nested-container host.
      if [[ ! -f /run/t2-fellback ]]; then
        touch /run/t2-fellback
        echo 'xray-sub.service: Failed to set up mount namespacing: Operation not supported' > /run/t2-journal
        exit 1
      fi
      port=$(tr -d '\r\n' </etc/xray-sub/port 2>/dev/null || echo 2096)
      [[ -f /run/t2-sub.pid ]] && kill "$(cat /run/t2-sub.pid)" 2>/dev/null || true
      /usr/bin/busybox httpd -f -p "127.0.0.1:$port" -h /srv/sub >/dev/null 2>&1 &
      echo $! > /run/t2-sub.pid
    fi;;
  is-failed) [[ -f /run/t2-journal ]] && exit 0 || exit 1;;
  enable|disable|daemon-reload|reset-failed) :;;
  show) :;;
esac
EOF
cat > /test-shims2/journalctl <<'EOF'
#!/usr/bin/env bash
cat /run/t2-journal 2>/dev/null || true
EOF
chmod +x /test-shims2/*
echo 'PASS: fallback shim installed'
