#!/usr/bin/env bash
# 用手机上的 TrollStore 正规安装 IPA —— 走 installd，App 才有真正的沙箱容器与图标。
#
# 为什么值得多这几步（都是实测踩出来的）：
#   1. 自己 `cp -R` 到 /var/jb/Applications 的 App **没有数据容器**：
#      Documents / Library/Caches / Library/Preferences 全不可写，UserDefaults 写完全静默丢弃
#      （见 README 里「这台机器上的 UserDefaults 是假的」）。
#   2. 那条路 SpringBoard 也拿不到图标，桌面上永远是系统的网格占位图。
#   3. trollstorehelper 在**已安装**状态下会返回 179（装不进去），必须先用 `uninstall` 卸掉；
#      传第二个参数 `1`（force）会返回 166，也不通。
#
# 用法：
#   bash scripts/install-trollstore.sh
set -euo pipefail

HOST="${HOST:-192.168.0.102}"
USER_NAME="${USER_NAME:-root}"
PASS="${PASS:-alpine}"
BUNDLE_ID="${BUNDLE_ID:-app.faios.client}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${IPA:-$ROOT/build/FAIOS.ipa}"
REMOTE_IPA="/var/mobile/Media/FAIOS.ipa"
TROLLSTORE="/var/containers/Bundle/Application/460BF923-C031-4704-801B-62F9122F5F14/TrollStore.app"

[ -f "$IPA" ] || { echo "找不到 ipa: $IPA（先跑 scripts/build.sh）"; exit 1; }

export SSHPASS="$PASS"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)

echo "→ 推送 $(du -h "$IPA" | cut -f1) 到 $HOST"
sshpass -e ssh "${SSHO[@]}" -T "$USER_NAME@$HOST" "cat > $REMOTE_IPA" < "$IPA"

echo "→ 卸载旧版本（trollstorehelper 对已安装的 App 会直接返回 179）"
sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "
  killall FAIOS 2>/dev/null || true
  '$TROLLSTORE/trollstorehelper' uninstall '$BUNDLE_ID' 2>/dev/null | tail -2 || true
  rm -rf /var/jb/Applications/FAIOS.app
  /var/jb/usr/bin/uicache -a >/dev/null 2>&1 || true
"

echo "→ TrollStore 安装"
sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "
  set -e
  '$TROLLSTORE/trollstorehelper' install '$REMOTE_IPA' 2>&1 | grep -E 'returning|force' || true
  /var/jb/usr/bin/uicache -a >/dev/null 2>&1 || true
  sleep 1
  /var/jb/usr/bin/uicache -l 2>/dev/null | grep -i faios || echo '⚠️ 没注册上'
"

echo "✅ 装好了（TrollStore 版：有真实容器、桌面有图标）"
