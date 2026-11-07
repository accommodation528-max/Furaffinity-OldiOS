#!/usr/bin/env bash
# 把构建好的 FAIOS.ipa 装到测试机（iPhone 7 Plus / iOS 15.8.3 / Dopamine rootless）。
#
# 不需要 Mac、不需要 Apple ID、不需要数据线 —— 走局域网 SSH。
# 原理：rootless 越狱机可以直接往 /var/jb/Applications 里放 .app，
#       ldid 重签后 uicache 注册进 LaunchServices。
#
# 用法：
#   bash scripts/install-device.sh                 # 用默认设备
#   HOST=192.168.0.102 bash scripts/install-device.sh
set -euo pipefail

HOST="${HOST:-192.168.0.102}"
USER_NAME="${USER_NAME:-root}"
PASS="${PASS:-alpine}"
IPA="${IPA:-$(cd "$(dirname "$0")/.." && pwd)/FAIOS/xtool/FAIOS.ipa}"
BUNDLE_ID="${BUNDLE_ID:-app.faios.client}"
REMOTE_IPA="/var/mobile/Media/FAIOS.ipa"
REMOTE_APP="/var/jb/Applications/FAIOS.app"

[ -f "$IPA" ] || { echo "找不到 ipa: $IPA（先跑 xtool dev build --ipa）"; exit 1; }

export SSHPASS="$PASS"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)

echo "→ 推送 $(du -h "$IPA" | cut -f1) 到 $HOST"
sshpass -e ssh "${SSHO[@]}" -T "$USER_NAME@$HOST" "cat > $REMOTE_IPA" < "$IPA"

echo "→ 解包 / 重签 / 注册"
sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "set -e
  killall -9 $(basename "${BUNDLE_ID##*.}") 2>/dev/null || true
  rm -rf /tmp/faios-ipa && mkdir -p /tmp/faios-ipa
  /var/jb/usr/bin/unzip -q -o $REMOTE_IPA -d /tmp/faios-ipa
  rm -rf $REMOTE_APP
  cp -R /tmp/faios-ipa/Payload/FAIOS.app $REMOTE_APP
  chmod 755 $REMOTE_APP/FAIOS
  /var/jb/usr/bin/ldid -S $REMOTE_APP/FAIOS
  /var/jb/usr/bin/uicache -a >/dev/null 2>&1
  /var/jb/usr/bin/uicache -l 2>/dev/null | grep -i faios"

echo "✅ 装好了。桌面上找「FAIOS」。"
