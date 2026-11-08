#!/usr/bin/env bash
# 一条命令构建出可装机的 ipa：编译 → 拷进 build/ → 补 Info.plist（后台音频）。
#
# 用法（在 WSL 里跑）：
#   bash /mnt/d/faios/scripts/build.sh
#
# 为什么要单独补 Info.plist：xtool 生成的 plist 没有 UIBackgroundModes，
# 没有它音乐一进后台就停，锁屏也不显示。见 scripts/patch-ipa.py。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/FAIOS"

echo "→ 编译（约 30-40 秒）"
xtool dev build --ipa

echo "→ 拷到 build/"
cp xtool/FAIOS.ipa "$ROOT/build/FAIOS.ipa"

echo "→ 补 Info.plist"
python3 "$ROOT/scripts/patch-ipa.py" "$ROOT/build/FAIOS.ipa"

SIZE="$(du -h "$ROOT/build/FAIOS.ipa" | cut -f1)"
echo "✅ $ROOT/build/FAIOS.ipa ($SIZE)"
echo "   装机：bash scripts/install-device.sh"
