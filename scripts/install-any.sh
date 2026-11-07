#!/usr/bin/env bash
# 通用装机：把任意 ipa 里的 .app 拷进 /var/jb/Applications 并 ldid 重签 + uicache。
#   bash scripts/install-any.sh <ipa> <AppName 不带 .app>
set -euo pipefail

HOST="${HOST:-192.168.0.102}"
USER_NAME="${USER_NAME:-root}"
PASS="${PASS:-alpine}"
IPA="$1"
APP="$2"
REMOTE_IPA="/var/mobile/Media/$APP.ipa"
REMOTE_APP="/var/jb/Applications/$APP.app"

[ -f "$IPA" ] || { echo "找不到 ipa: $IPA"; exit 1; }

export SSHPASS="$PASS"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)

echo "→ 推送 $APP"
sshpass -e ssh "${SSHO[@]}" -T "$USER_NAME@$HOST" "cat > $REMOTE_IPA" < "$IPA"

sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "
  set -e
  kick() { killall -9 $(echo $APP | tr 'A-Z' 'a-z') 2>/dev/null || true; }
  kick
  rm -rf /tmp/ipa-$APP && mkdir -p /tmp/ipa-$APP
  /var/jb/usr/bin/unzip -q -o $REMOTE_IPA -d /tmp/ipa-$APP
  rm -rf $REMOTE_APP
  cp -R /tmp/ipa-$APP/Payload/$APP.app $REMOTE_APP
  chmod -R 755 $REMOTE_APP
  chown -R mobile:mobile $REMOTE_APP
  /var/jb/usr/bin/ldid -S $REMOTE_APP/$APP
  /var/jb/usr/bin/uicache -a >/dev/null 2>&1
  /var/jb/usr/bin/uicache -l 2>/dev/null | grep -i $APP || echo '（未出现在 uicache）'
"
echo "✅ $APP 装好了"
