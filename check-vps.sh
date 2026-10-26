#!/usr/bin/env bash
# Read-only environment check. Prints no secrets and changes nothing.
set -u
printf '\n--- OS ---\n'
cat /etc/os-release
uname -m
printf '\n--- PID 1 / virtualization ---\n'
ps -p 1 -o comm= 2>/dev/null || true
systemd-detect-virt 2>/dev/null || true
printf '\n--- memory / filesystem ---\n'
free -m 2>/dev/null || true
df -h /
printf '\n--- listeners ---\n'
ss -lntup 2>/dev/null || true
printf '\n--- time ---\n'
date -u
printf '\nNow confirm your cloud port-forwarding table and public IP before installing.\n'
