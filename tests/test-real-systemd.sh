#!/usr/bin/env bash
# End-to-end installer test against the real systemd PID 1 in the review container.
# The only shims are release download, external HTTP status, and target TLS output.
set -Eeuo pipefail

root=${ROOT:-/work}
sub_user=xray-sub
state=/usr/local/etc/xray/client.json
sub_dir=/etc/$sub_user
sub_service=$sub_user
sub_port=${SUB_LISTEN_PORT:-18996}
proxy_port=${LISTEN_PORT:-18443}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail 'must run as root'
[[ -r /proc/1/comm ]] && [[ $(tr -d '\n' </proc/1/comm) == systemd ]] || fail 'PID 1 is not real systemd'
[[ -d /run/systemd/system ]] || fail 'systemd runtime directory is missing'
[[ -d $root ]] || fail 'source root is missing'
[[ -f /release.zip ]] || fail 'release fixture /release.zip is missing'

payload=$(mktemp -d /run/xray-real-systemd.payload.XXXXXX)
shimdir=$(mktemp -d /run/xray-real-systemd.shims.XXXXXX)
request_dir=$(mktemp -d /run/xray-real-systemd.requests.XXXXXX)
chmod 733 "$request_dir"

cleanup_node() {
  set +e
  systemctl stop xray "$sub_service" >/dev/null 2>&1
  systemctl disable xray "$sub_service" >/dev/null 2>&1
  systemctl reset-failed xray "$sub_service" >/dev/null 2>&1
  rm -rf \
    /usr/local/etc/xray \
    /usr/local/share/xray \
    /usr/local/bin/xray \
    /usr/local/sbin/xray-admin \
    /usr/local/sbin/$sub_user \
    /etc/systemd/system/xray.service \
    /etc/systemd/system/$sub_service.service \
    /etc/${sub_user:?} \
    /srv/sub \
    /root/xray-backups \
    /root/xray-client \
    /root/xray-subscription.txt
  rm -f \
    /etc/systemd/system/multi-user.target.wants/xray.service \
    /etc/systemd/system/multi-user.target.wants/$sub_service.service
  userdel "$sub_user" >/dev/null 2>&1
  groupdel "$sub_user" >/dev/null 2>&1
  userdel xray >/dev/null 2>&1
  groupdel xray >/dev/null 2>&1
  systemctl daemon-reload >/dev/null 2>&1
}

cleanup() {
  cleanup_node
  rm -rf "$payload" "$shimdir" "$request_dir"
}
trap cleanup EXIT

cleanup_node

for file in install-xray.sh xray-admin rules.template.yaml "$sub_user" "$sub_user.service"; do
  [[ -f $root/$file ]] || fail "source payload is missing"
  cp -- "$root/$file" "$payload/$file"
done
chmod 700 "$payload/install-xray.sh" "$payload/xray-admin" "$payload/$sub_user"

cat >"$shimdir/curl" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
args=("$@")
last=${args[${#args[@]}-1]}
output=
write_status=0
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -o|--output)
      ((i + 1 < ${#args[@]})) || exit 2
      output=${args[i + 1]}
      ;;
    -w|--write-out)
      write_status=1
      ;;
  esac
done
if [[ $last == *releases/download* ]]; then
  [[ -n $output && $output != - ]] || exit 2
  cp -- /release.zip "$output"
  exit 0
fi
case $last in
  http://127.0.0.1:*|http://localhost:*)
    exec /usr/bin/curl "$@"
    ;;
esac
if ((write_status)); then
  printf '200'
  exit 0
fi
exit 1
SHIM

cat >"$shimdir/openssl" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == s_client ]]; then
  printf 'TLSv1.3\nALPN protocol: h2\n'
  exit 0
fi
exec /usr/bin/openssl "$@"
SHIM
chmod 755 "$shimdir/curl" "$shimdir/openssl"
export PATH=$shimdir:$PATH

systemctl --version 2>/dev/null | grep -q '^systemd ' || fail 'systemctl is not the real systemd client'
[[ ! -e $shimdir/systemctl ]] || fail 'systemctl was shimmed'
getent ahostsv4 example.com >/dev/null 2>&1 || fail 'real getent cannot resolve example.com'

export SERVER_ADDRESS=203.0.113.10
export PUBLIC_PORT=34439
export LISTEN_PORT=$proxy_port
export REALITY_DEST=example.com:443
export REALITY_SERVER_NAME=example.com
export SUB_PUBLIC_PORT=34441
export SUB_LISTEN_PORT=$sub_port

if ! bash "$payload/install-xray.sh" --install >/dev/null 2>&1; then
  fail 'initial real-systemd install failed'
fi

assert_active() {
  systemctl is-active --quiet "$1" || fail 'service is not active'
}

assert_listener() {
  ss -lntH "sport = :$1" 2>/dev/null | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*):' || fail 'listener is not bound to the container interface'
}

assert_service_user() {
  local unit=$1 expected=$2 pid actual
  pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
  [[ $pid =~ ^[1-9][0-9]*$ ]] || fail 'service has no real MainPID'
  actual=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ $actual == "$expected" ]] || fail 'service process is not running as its configured user'
}

assert_active xray
assert_active "$sub_service"
assert_listener "$proxy_port"
assert_listener "$sub_port"
assert_service_user xray xray
assert_service_user "$sub_service" "$sub_user"
chown "$sub_user:$sub_user" "$request_dir"
systemctl is-enabled --quiet xray || fail 'xray is not enabled'
systemctl is-enabled --quiet "$sub_service" || fail 'subscription service is not enabled'

# Exercise stop/start through the real systemctl before testing reinstall behavior.
systemctl stop "$sub_service" xray >/dev/null 2>&1 || fail 'real systemctl stop failed'
! systemctl is-active --quiet xray || fail 'xray did not stop'
! systemctl is-active --quiet "$sub_service" || fail 'subscription service did not stop'
systemctl start xray >/dev/null 2>&1 || fail 'real systemctl start xray failed'
systemctl start "$sub_service" >/dev/null 2>&1 || fail 'real systemctl start subscription failed'
sleep 2
assert_active xray
assert_active "$sub_service"
assert_listener "$proxy_port"
assert_listener "$sub_port"

uuid_before=$(jq -er .uuid "$state") || fail 'installed UUID is missing'
token_before=$(tr -d '\r\n' <"$sub_dir/token") || fail 'installed token is missing'
[[ $uuid_before =~ ^[0-9a-fA-F-]{36}$ ]] || fail 'installed UUID has an invalid shape'
[[ $token_before =~ ^[A-Za-z0-9_-]{16,64}$ ]] || fail 'installed token has an invalid shape'
private_key=$(jq -er .private_key "$state") || fail 'installed private key is missing'

# Create quota data with the exact parent/file permissions used by the CGI service.
printf '%s\n' 'upload=0; download=53687091200; total=107374182400; expire=1800000000' >"$sub_dir/userinfo"
chown root:"$sub_user" "$sub_dir/userinfo"
chmod 640 "$sub_dir/userinfo"
[[ $(stat -c %a "$sub_dir") == 750 ]] || fail 'subscription parent directory mode is wrong'
[[ $(stat -c %a "$sub_dir/userinfo") == 640 ]] || fail 'quota file mode is wrong'
runuser -u "$sub_user" -- test -r "$sub_dir/userinfo" || fail 'real subscription user cannot read quota data'
bash "$payload/$sub_user" >/dev/null 2>&1 || fail 'subscription regeneration failed'

fetch_loopback() {
  local url=$1
  NO_PROXY='*' /usr/bin/curl -fsS -D "$request_dir/loopback.headers" \
    -o "$request_dir/loopback.body" --max-time 5 "$url" >/dev/null 2>&1
}

fetch_nic_as_sub_user() {
  local url=$1
  runuser -u "$sub_user" -- env NO_PROXY='*' /usr/bin/curl -fsS \
    -D "$request_dir/nic.headers" -o "$request_dir/nic.body" --max-time 5 "$url" \
    >/dev/null 2>&1
}

loopback_url="http://127.0.0.1:$sub_port/cgi-bin/$token_before"
fetch_loopback "$loopback_url" || fail 'loopback subscription fetch failed'
grep -q '^Subscription-Userinfo: upload=0; download=53687091200; total=107374182400; expire=1800000000' \
  "$request_dir/loopback.headers" || fail 'loopback quota header is missing'
grep -q 'MATCH,PROXY' "$request_dir/loopback.body" || fail 'loopback subscription body is incomplete'
grep -Eqi 'private[_-]?key|privateKey' "$request_dir/loopback.body" && fail 'subscription body contains a private-key field'
grep -Fq "$private_key" "$request_dir/loopback.body" && fail 'subscription body contains the private key'
rm -f "$request_dir/nic.headers" "$request_dir/nic.body"

container_ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
[[ $container_ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail 'container NIC address is missing'
nic_url="http://$container_ip:$sub_port/cgi-bin/$token_before"
if ! fetch_nic_as_sub_user "$nic_url"; then
  nic_code=$(runuser -u "$sub_user" -- env NO_PROXY='*' /usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$nic_url" 2>/dev/null || printf 'curl-error')
  nic_rc=0
  runuser -u "$sub_user" -- env NO_PROXY='*' /usr/bin/curl -sS -D "$request_dir/nic-debug.headers" -o "$request_dir/nic-debug.body" --max-time 5 "$nic_url" >/dev/null 2>&1 || nic_rc=$?
  nic_files=$(find "$request_dir" -maxdepth 1 -type f -printf '%f:%s ' 2>/dev/null || true)
  fail "container-NIC subscription fetch failed (rc $nic_rc HTTP $nic_code; files $nic_files)"
fi
grep -q '^Subscription-Userinfo: upload=0; download=53687091200; total=107374182400; expire=1800000000' \
  "$request_dir/nic.headers" || fail 'container-NIC quota header is missing'
grep -q 'MATCH,PROXY' "$request_dir/nic.body" || fail 'container-NIC subscription body is incomplete'
grep -Eqi 'private[_-]?key|privateKey' "$request_dir/nic.body" && fail 'container-NIC body contains a private-key field'
grep -Fq "$private_key" "$request_dir/nic.body" && fail 'container-NIC body contains the private key'

# Reinstall through the real units and prove identity stability.
if ! bash "$payload/install-xray.sh" --install >/dev/null 2>&1; then
  fail 'reinstall failed'
fi
uuid_after=$(jq -er .uuid "$state") || fail 'UUID disappeared after reinstall'
token_after=$(tr -d '\r\n' <"$sub_dir/token") || fail 'token disappeared after reinstall'
[[ $uuid_after == "$uuid_before" ]] || fail 'UUID changed on reinstall'
[[ $token_after == "$token_before" ]] || fail 'subscription token changed on reinstall'
assert_active xray
assert_active "$sub_service"
assert_listener "$proxy_port"
assert_listener "$sub_port"

hash_paths=(
  usr/local/etc/xray
  usr/local/bin/xray
  usr/local/share/xray
  usr/local/sbin/xray-admin
  "usr/local/sbin/$sub_user"
  etc/systemd/system/xray.service
  "etc/systemd/system/$sub_service.service"
  etc/systemd/system/multi-user.target.wants/xray.service
  "etc/systemd/system/multi-user.target.wants/$sub_service.service"
  "etc/$sub_user"
  srv/sub
)

snapshot() {
  local output=$1 path
  : >"$output"
  for path in "${hash_paths[@]}"; do
    if [[ -e /$path || -L /$path ]]; then
      printf '%s\t' "$path" >>"$output"
      tar --sort=name --mtime='@0' --numeric-owner -C / -cf - -- "$path" 2>/dev/null \
        | sha256sum | awk '{print $1}' >>"$output"
    else
      printf '%s\tABSENT\n' "$path" >>"$output"
    fi
  done
}

before_snapshot="$request_dir/before.snapshot"
after_snapshot="$request_dir/after.snapshot"
snapshot "$before_snapshot"

# Replace only the copied payload's subscription unit with an invalid ExecStart.
sed 's|^ExecStart=.*|ExecStart=/run/this-command-does-not-exist|' \
  "$payload/$sub_user.service" >"$payload/$sub_user.service.invalid"
mv -f "$payload/$sub_user.service.invalid" "$payload/$sub_user.service"
grep -q '^ExecStart=/run/this-command-does-not-exist$' "$payload/$sub_user.service" \
  || fail 'failure fixture was not installed'

if bash "$payload/install-xray.sh" --install >/dev/null 2>&1; then
  fail 'invalid subscription unit was accepted'
fi
snapshot "$after_snapshot"
cmp -s "$before_snapshot" "$after_snapshot" || fail 'failed install changed the full installed file snapshot'
assert_active xray
assert_active "$sub_service"
assert_listener "$proxy_port"
assert_listener "$sub_port"
systemctl is-enabled --quiet xray || fail 'xray enablement was not restored'
systemctl is-enabled --quiet "$sub_service" || fail 'subscription enablement was not restored'

printf 'PASS: real systemd install, NIC/loopback CGI, quota permissions, stable identity, and rollback\n'
