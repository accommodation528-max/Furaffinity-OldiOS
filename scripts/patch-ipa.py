#!/usr/bin/env python3
"""给打包好的 ipa 补上 xtool 不会生成、但我们需要的 Info.plist 键与资源。

目前做两件事：

1. `UIBackgroundModes = ["audio"]` —— 没有它，一按 home 音乐就停，
   锁屏 / 控制中心也拿不到播放状态。
2. 塞进 `scripts/icons/Icon-*.png` 并登记 `CFBundleIconFiles` ——
   否则装到桌面上是一个空白图标（xtool 不生成 asset catalog）。

`xtool.yml` 只认 version 与 bundleID，所以只能在产物上打补丁。

用法：python3 scripts/patch-ipa.py build/FAIOS.ipa
"""

import plistlib
import shutil
import sys
import zipfile
from pathlib import Path

WANTED_BACKGROUND_MODES = ["audio"]
ICON_DIR = Path(__file__).resolve().parent / "icons"
# 完整文件名列表（带 @2x/@3x 后缀，所以不用 CFBundleIconFiles 的自动变体查找）
ICON_FILES = [
    "Icon-60@2x.png",
    "Icon-60@3x.png",
    "Icon-76.png",
    "Icon-76@2x.png",
    "Icon-40@2x.png",
    "Icon-40@3x.png",
    "Icon-29@2x.png",
    "Icon-29@3x.png",
]


def next_build_number(build_dir: Path) -> int:
    counter = build_dir / ".buildnumber"
    try:
        current = int(counter.read_text().strip())
    except (OSError, ValueError):
        current = 0
    value = current + 1
    try:
        counter.write_text(str(value))
    except OSError:
        pass
    return value


def patch_app_plist(path: str) -> int:
    with zipfile.ZipFile(path) as source:
        entries = source.infolist()
        app_plist = next(
            (info for info in entries if info.filename.endswith(".app/Info.plist")), None
        )
        if app_plist is None:
            print(f"x {path}: no .app/Info.plist")
            return 1
        payloads = {info.filename: source.read(info.filename) for info in entries}

    app_prefix = app_plist.filename[: -len("Info.plist")]
    plist = plistlib.loads(payloads[app_plist.filename])

    changed = []

    modes = list(plist.get("UIBackgroundModes", []))
    merged = sorted(set(modes) | set(WANTED_BACKGROUND_MODES))
    if merged != modes:
        plist["UIBackgroundModes"] = merged
        changed.append(f"UIBackgroundModes {modes} -> {merged}")

    if ICON_DIR.is_dir():
        present = []
        for name in ICON_FILES:
            source = ICON_DIR / name
            if not source.exists():
                continue
            payloads[app_prefix + name] = source.read_bytes()
            present.append(name)
        if present:
            plist["CFBundleIconFiles"] = present
            plist["CFBundleIcons"] = {
                "CFBundlePrimaryIcon": {"CFBundleIconFiles": present}
            }
            changed.append(f"icons x{len(present)}")

    # 每次构建都涨一个 build 号：
    # SpringBoard 的图标缓存按 bundle version 判定是否失效，
    # 版本号不变时换了图标也只会继续显示旧图（或占位图）。
    build_number = next_build_number(Path(path).resolve().parent)
    plist["CFBundleVersion"] = str(build_number)
    plist["CFBundleShortVersionString"] = f"0.5.{build_number}"
    changed.append(f"build {build_number}")

    if not changed:
        print("= ipa 已经是目标状态，不需要改")
        return 0

    payloads[app_plist.filename] = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)

    tmp = path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as target:
        written = set()
        for info in entries:
            target.writestr(info, payloads[info.filename])
            written.add(info.filename)
        # 新增的图标文件（原 zip 里没有）
        for name in payloads:
            if name in written:
                continue
            target.writestr(name, payloads[name])
    shutil.move(tmp, path)

    print("OK " + "; ".join(changed))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(patch_app_plist(sys.argv[1]))
