#!/usr/bin/env bash
# 在测试机上执行一条命令（走局域网 SSH）。
#   bash scripts/device.sh 'uicache -l | grep -i faios'
#
# 连接信息不写进仓库：复制 scripts/device.env.example 为 scripts/device.env 再填。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$here/device.env" ]; then . "$here/device.env"; fi

HOST="${HOST:-}"
USER_NAME="${USER_NAME:-root}"
PASS="${PASS:-}"
if [ -z "$HOST" ] || [ -z "$PASS" ]; then
  echo "缺少 HOST / PASS：cp scripts/device.env.example scripts/device.env 后填好再跑" >&2
  exit 2
fi

export SSHPASS="$PASS"
exec sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=8 -o LogLevel=ERROR "$USER_NAME@$HOST" "$@"
