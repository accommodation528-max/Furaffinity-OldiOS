#!/usr/bin/env bash
# 在测试机上执行一条命令（走局域网 SSH）。
#   bash scripts/device.sh 'uicache -l | grep -i faios'
set -euo pipefail
HOST="${HOST:-192.168.0.102}"
USER_NAME="${USER_NAME:-root}"
PASS="${PASS:-alpine}"
export SSHPASS="$PASS"
exec sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=8 -o LogLevel=ERROR "$USER_NAME@$HOST" "$@"
