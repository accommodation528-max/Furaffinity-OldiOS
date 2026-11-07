#!/usr/bin/env bash
# 用手机上的 TrollStore 正规安装 IPA（走 installd，App 有真正的容器、SpringBoard 能正常启动）。
#
# 和自己往 /var/jb/Applications 里拷 .app 相比，这条路才能被 uiopen / SpringBoard 正常拉起。
#   bash scripts/install-trollstore.sh
set -euo pipefail

HOST="${HOST:-192.168.0.102}"
USER_NAME="${USER_NAME:-root}"
PASS="${PASS:-alpine}"
IPA="${IPA:-$(cd "$(dirname "$0")/.." && pwd)/FAIOS/xtool/FAIOS.ipa}"
REMOTE_IPA="/var/mobile/Media/FAIOS.ipa"
TROLLSTORE="/var/containers/Bundle/Application/460BF923-C031-4704-801B-62F9122F5F14/TrollStore.app"

[ -f "$IPA" ] || { echo "找不到 ipa: $IPA"; exit 1; }

export SSHPASS="$PASS"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)

echo "→ 推送 $(du -h "$IPA" | cut -f1) 到 $HOST"
sshpass -e ssh "${SSHO[@]}" -T "$USER_NAME@$HOST" "cat > $REMOTE_IPA" < "$IPA"

echo "→ TrollStore 安装"
sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "
  set -e
  killall FAIOS 2>/dev/null || true
  '$TROLLSTORE/trollstorehelper' install '$REMOTE_IPA' 2>&1 | tail -3
  /var/jb/usr/bin/uicache -a 2>/dev/null || true
  sleep 1
  /var/jb/usr/bin/uicache -l 2>/dev/null | grep -i faios || true
"

echo "✅ 装好了"
