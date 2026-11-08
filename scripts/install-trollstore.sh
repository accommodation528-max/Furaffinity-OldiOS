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
#   4. 卸载会把数据容器一起删掉 → 每次升级都丢设置、丢下载、丢阅读进度。
#      所以这里先备份 `Documents/FAIOS`，装完再恢复（App 自己的数据只在 Documents 下）。
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
BACKUP="/var/tmp/faios-container-backup.tar"

[ -f "$IPA" ] || { echo "找不到 ipa: $IPA（先跑 scripts/build.sh）"; exit 1; }

export SSHPASS="$PASS"
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)

# 找到我们这个 bundle id 的数据容器（容器目录名是随机 UUID，只能靠 metadata.plist 认领）
CONTAINER_FINDER='D=""
for d in /var/mobile/Containers/Data/Application/*/; do
  strings "$d.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null | grep -q "app.faios.client" && D="$d" && break
done
echo "$D"'

echo "→ 推送 $(du -h "$IPA" | cut -f1) 到 $HOST"
sshpass -e ssh "${SSHO[@]}" -T "$USER_NAME@$HOST" "cat > $REMOTE_IPA" < "$IPA"

echo "→ 备份现有数据容器里的 Documents/FAIOS"
sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "
  D=\$($CONTAINER_FINDER)
  rm -f '$BACKUP'
  if [ -n \"\$D\" ] && [ -d \"\$D/Documents/FAIOS\" ]; then
    cd \"\$D/Documents\" && tar cf '$BACKUP' FAIOS && echo \"  backed up: \$(du -h '$BACKUP' | cut -f1)\"
  else
    echo '  no data to back up'
  fi
"

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

echo "→ 恢复数据（设置 / 下载 / 阅读进度）"
sshpass -e ssh "${SSHO[@]}" "$USER_NAME@$HOST" "
  if [ -f '$BACKUP' ]; then
    D=\$($CONTAINER_FINDER)
    if [ -n \"\$D\" ]; then
      mkdir -p \"\$D/Documents\"
      cd \"\$D/Documents\" && tar xf '$BACKUP' && rm -f '$BACKUP'
      chown -R mobile:mobile \"\$D/Documents/FAIOS\"
      echo '  restored'
    else
      echo '  ⚠️ 找不到新容器，备份留在 $BACKUP'
    fi
  fi
"

echo "✅ 装好了（TrollStore 版：有真实容器、桌面有图标、设置已保留）"
