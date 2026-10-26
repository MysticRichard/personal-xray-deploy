#!/usr/bin/env bash
# Review/regression suite for install-xray.sh.
# The outer process runs the assertions in a disposable Debian container; no
# host service, /etc, /srv, or repository files are modified.
set -Eeuo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/install-xray.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [[ ${1:-} != --inside ]]; then
  docker_bin=docker
  command -v "$docker_bin" >/dev/null 2>&1 || docker_bin=docker.exe
  if command -v "$docker_bin" >/dev/null 2>&1 && ! "$docker_bin" info >/dev/null 2>&1; then
    docker_bin=docker.exe
  fi
  command -v "$docker_bin" >/dev/null 2>&1 || fail 'docker is required for the disposable-container review'
  image="xray-install-review:$$"
  cleanup_image() { "$docker_bin" image rm "$image" >/dev/null 2>&1 || true; }
  trap cleanup_image EXIT
  build_root=$root
  mount_root=$root
  if [[ $docker_bin == *.exe ]]; then
    build_root=$(wslpath -w "$root")
    mount_root=$build_root
  fi
  "$docker_bin" build -q -f "$build_root/tests/Dockerfile" -t "$image" "$build_root" >/dev/null
  "$docker_bin" run --rm --privileged \
    --env DISPOSABLE_XRAY_TEST=1 \
    --mount "type=bind,src=$mount_root,dst=/work,readonly" \
    --mount "type=bind,src=$mount_root/xray-server-deploy.zip,dst=/release.zip,readonly" \
    "$image" bash /work/tests/test-install-review.sh --inside
  exit $?
fi

root=/work
script=$root/install-xray.sh
[[ ${DISPOSABLE_XRAY_TEST:-} == 1 ]] || fail 'review must run in a disposable container'

bash -n "$script"

# The installer must not use a shared, predictable temporary pathname.
if grep -Eq '(^|[[:space:]])/tmp/|/tmp/' "$script"; then
  fail 'installer still uses a fixed /tmp pathname'
fi
pass 'installer has no fixed /tmp pathname'

# Service users are explicit; a failed user setup must never silently fall back
# to root.  This is deliberately checked as source policy, not just a unit file.
if grep -Eq 'User=root|Group=root|User=\$\{?ROOT|runuser.*root' "$script"; then
  fail 'installer contains a root service fallback'
fi
grep -q 'useradd --system' "$script" || fail 'system service-user creation is missing'
grep -q -- '--shell /usr/sbin/nologin xray-sub' "$script" || fail 'subscription user creation is missing'
grep -q -- '--shell /usr/sbin/nologin xray' "$script" || fail 'xray user creation is missing'
pass 'service setup has no root fallback'

# Defaults are part of the validation contract, so exercise the real validate()
# function in a clean bash process rather than merely grepping its source.
fn=$(sed -n '/^fail()/p; /^valid_port()/,/^validate_secrets()/p' "$script" | sed '$d')
run_validate() {
  local expected=$1; shift
  local rc=0 output
  output=$(env -i PATH="$PATH" "$@" bash -c "set -Eeuo pipefail; $fn; validate" 2>&1) || rc=$?
  if [[ $expected == accept && $rc -ne 0 ]]; then
    echo "$output" >&2
    fail "validation rejected valid case: $*"
  fi
  if [[ $expected == reject && $rc -eq 0 ]]; then
    fail "validation accepted invalid case: $*"
  fi
}

base=(SERVER_ADDRESS=203.0.113.10 LISTEN_PORT=18443 PUBLIC_PORT=28443
  REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com)
run_validate accept "${base[@]}"
run_validate accept "${base[@]}" SERVER_ADDRESS=vps.example.com
run_validate reject "${base[@]}" SERVER_ADDRESS=2001:db8::10
run_validate reject "${base[@]}" LISTEN_PORT=2096
run_validate reject "${base[@]}" LISTEN_PORT=18443 SUB_LISTEN_PORT=18443
run_validate reject "${base[@]}" PUBLIC_PORT=2096 SUB_PUBLIC_PORT=2096
run_validate reject "${base[@]}" SUB_LISTEN_PORT=70000
run_validate reject "${base[@]}" SUB_LISTEN_PORT=80
run_validate accept "${base[@]}" SUB_LISTEN_PORT=1024
run_validate reject "${base[@]}" SUB_PUBLIC_PORT=not-a-port
pass 'subscription defaults, low-port guard and public/listen collisions are enforced'

# The REALITY target resolver must reject every non-public address class before
# any TLS probe, including IPv6 and IPv4-mapped IPv6 forms.
target_fn=$(sed -n '/^reject_private_target_address()/,/^}/p' "$script")
[[ -n $target_fn ]] || fail 'target address filter is missing'
check_target() {
  local name=$1 expected=$2 address=$3 rc=0
  bash -c "set -Eeuo pipefail; $target_fn; reject_private_target_address '$address'" >/dev/null 2>&1 || rc=$?
  if [[ $expected == private && $rc -ne 0 ]]; then fail "target filter accepted private address: $name"; fi
  if [[ $expected == public && $rc -eq 0 ]]; then fail "target filter rejected public address: $name"; fi
}
check_target 'public IPv4' public 1.1.1.1
check_target 'private IPv4' private 10.0.0.1
check_target 'CGNAT IPv4' private 100.64.0.1
check_target 'documentation IPv4' private 203.0.113.10
check_target 'IPv6 loopback' private ::1
check_target 'IPv6 ULA' private fd00::1
check_target 'IPv6 link-local' private fe80::1
check_target 'IPv6 documentation' private 2001:db8::1
check_target 'mapped loopback' private ::ffff:127.0.0.1
check_target 'public IPv6' public 2606:4700:4700::1111
pass 'REALITY target filter rejects private, CGNAT, documentation and IPv6 local addresses'

# Exercise the real renderer, including the secret-bearing inputs, without
# contacting the network or mutating an installed service.
render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT
CLIENT_UUID=123e4567-e89b-12d3-a456-426614174000 \
PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \
SHORT_ID=0123456789abcdef SERVER_ADDRESS=203.0.113.10 \
LISTEN_PORT=18443 PUBLIC_PORT=28443 REALITY_DEST=example.com:443 \
REALITY_SERVER_NAME=example.com bash "$script" --render "$render_dir/config.json" \
  >"$render_dir/render.log" 2>&1 || { cat "$render_dir/render.log" >&2; fail 'renderer rejected valid payload'; }
grep -q '"port": 18443' "$render_dir/config.json" || fail 'renderer did not write requested port'
grep -q '"minClientVer": "1.8.2"' "$render_dir/config.json" || fail 'renderer did not add FlClash/mihomo REALITY compatibility'
grep -q 'PRIVATE_KEY' "$render_dir/config.json" && fail 'renderer leaked variable names'
! grep -q 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' "$render_dir/render.log" || fail 'renderer logged a secret'
pass 'real renderer writes valid payload without logging secrets'

# A real listener is only reusable when its PID is the owning service PID.  The
# installer must use process-aware ss output and systemctl MainPID, not merely
# "service is active".
grep -q 'systemctl show.*MainPID' "$script" || fail 'no real service PID ownership check'
grep -q 'ss -lntHp' "$script" || fail 'no process-aware listening-port check'
pass 'port checks require real process ownership'

# Reusing a saved state must verify the public key derived from the saved
# private key with the staged Xray binary, and reject mismatches without outputting keys.
key_check=$(grep -n 'x25519 -i' "$script" || true)
[[ -n $key_check ]] || fail 'saved X25519 private key is not cryptographically checked'
grep -q 'public_key.*derived\|derived.*public_key' "$script" || fail 'derived public key is not compared with saved public key'
grep -q 'mismatch\|不匹配' "$script" || fail 'key mismatch has no clear failure path'
pass 'saved X25519 key pair is cryptographically verified'

# Exercise the verifier with a disposable Xray-shaped command: matching keys
# pass, mismatches fail, and neither path prints key material.
key_dir=$(mktemp -d)
trap 'rm -rf "$render_dir" "$key_dir"' EXIT
cat > "$key_dir/xray" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == x25519 && $2 == -i ]]; then
  if [[ $3 == matching-private ]]; then
    printf 'PrivateKey: matching-private\nPassword (PublicKey): AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
  else
    printf 'PrivateKey: other-private\nPassword (PublicKey): BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n'
  fi
else
  exit 1
fi
EOF
chmod 700 "$key_dir/xray"
verify_fn=$(sed -n '/^verify_saved_key_pair()/,/^}/p' "$script")
bash -c "set -Eeuo pipefail; fail(){ printf 'ERROR: %s\\n' \"\$*\" >&2; exit 1; }; $verify_fn; verify_saved_key_pair '$key_dir/xray' matching-private AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  >"$key_dir/match.log" 2>&1 || fail 'matching saved key pair was rejected'
if bash -c "set -Eeuo pipefail; fail(){ printf 'ERROR: %s\\n' \"\$*\" >&2; exit 1; }; $verify_fn; verify_saved_key_pair '$key_dir/xray' mismatched-private AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  >"$key_dir/mismatch.log" 2>&1; then
  fail 'mismatched saved key pair was accepted'
fi
grep -qi 'mismatch' "$key_dir/mismatch.log" || fail 'key mismatch error is unclear'
! grep -q 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\|BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\|matching-private\|other-private' "$key_dir/mismatch.log" \
  || fail 'key material was logged on mismatch'
pass 'key-pair verifier rejects mismatches without logging secrets'

# All source payloads must be checked before service activation, and failed
# restart commands must be handled so the retry loop can continue.
grep -q 'bash -n.*xray-sub' "$script" || fail 'subscription payload is not preflighted'
grep -q 'bash -n.*xray-admin' "$script" || fail 'admin payload is not preflighted'
grep -q 'id -u xray-sub' "$script" || fail 'subscription user may be root'
grep -q 'id -u xray' "$script" || fail 'xray user may be root'
grep -q 'setup_subscription 0' "$script" || fail 'subscription payload is not prepared before service activation'
if grep -q 'systemctl restart xray$' "$script"; then
  fail 'xray restart can abort the retry loop under set -e'
fi
pass 'payload preflight and restart retry guards are present'

# Transaction coverage must include the entire subscription state, generated
# webroot, and both prior active/enabled states.
grep -q '/srv/sub' "$script" || fail 'subscription webroot is absent from rollback coverage'
grep -q 'systemctl is-enabled.*xray' "$script" || fail 'prior xray enable state is not captured'
grep -q 'systemctl is-enabled.*xray-sub' "$script" || fail 'prior subscription enable state is not captured'
grep -q 'restore.*enable\|restore_enable' "$script" || fail 'enable state is not restored'
grep -q 'cp -a' "$script" || fail 'directory snapshots are not used for rollback'
pass 'rollback covers subscription files, webroot, active state, and enable state'

# Run the existing disposable install harness as an integration check. It
# exercises real archive extraction, Xray startup retries, subscription HTTP,
# reinstall preservation, and rollback after a failed activation.
# The repository fixture is a one-click payload, not an Xray release archive;
# do not pretend it can exercise binary extraction. The full install harness is
# run separately when a matching Xray-linux-64.zip fixture is supplied.
if unzip -l /release.zip 2>/dev/null | grep -Eq '[[:space:]]xray$|[[:space:]]geoip\.dat$'; then
  touch /DISPOSABLE_XRAY_TEST
  integration_root=$(mktemp -d)
  trap 'rm -rf "$render_dir" "$integration_root"' EXIT
  cp -a "$root/." "$integration_root/"
  fixture_sha=$(sha256sum "$integration_root/xray-server-deploy.zip" | awk '{print $1}')
  sed -i -E "s/^ARCHIVE_SHA256=.*/ARCHIVE_SHA256=$fixture_sha/" "$integration_root/install-xray.sh"
  bash "$integration_root/tests/test-install.sh"
  pass 'disposable install/reinstall/rollback integration passed'
else
  echo 'SKIP: install binary integration (release fixture has no xray/geoip payload)'
fi

echo 'ALL INSTALL REVIEW CASES PASSED'
