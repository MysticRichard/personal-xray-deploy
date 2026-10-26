#!/usr/bin/env bash
# Read-only REALITY target probe. Prompts for a target; installs nothing.
set -u
read -r -p '要检测的目标域名: ' target
[[ $target =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo '域名格式不正确' >&2; exit 1; }
for tool in openssl curl timeout; do
  command -v "$tool" >/dev/null || { echo "缺少依赖: $tool" >&2; exit 1; }
done
printf '\n--- %s:443 ---\n' "$target"
if probe=$(timeout 15 openssl s_client -connect "$target:443" -servername "$target" \
     -verify_hostname "$target" -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1); then
  [[ $probe == *TLSv1.3* ]] && echo 'TLS 1.3: OK' || echo 'TLS 1.3: FAIL'
  [[ $probe == *'ALPN protocol: h2'* ]] && echo 'HTTP/2 : OK' || echo 'HTTP/2 : FAIL'
else
  echo '证书或连通性检查失败'
fi
curl --http1.1 --noproxy '*' --silent --show-error --max-time 15 -o /dev/null \
  -w 'HTTP=%{http_code} remote=%{remote_ip} connect=%{time_connect}s total=%{time_total}s\n' \
  "https://$target/" || true
echo '仅代表当前时刻的检测结果。'
