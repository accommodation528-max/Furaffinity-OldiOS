#!/usr/bin/env python3
"""给打包好的 ipa 补上 xtool 不会生成、但我们需要的 Info.plist 键。

目前只有一项：`UIBackgroundModes = ["audio"]` —— 没有它，一按 home 音乐就停，
锁屏 / 控制中心也拿不到播放状态。xtool.yml 只认 version 与 bundleID，
所以只能在产物上打补丁。

用法：python3 scripts/patch-ipa.py build/FAIOS.ipa
"""

import plistlib
import shutil
import sys
import zipfile

WANTED_BACKGROUND_MODES = ["audio"]


def main(path: str) -> int:
    with zipfile.ZipFile(path) as source:
        entries = source.infolist()
        app_plist = next(
            (info for info in entries if info.filename.endswith(".app/Info.plist")), None
        )
        if app_plist is None:
            print(f"✗ {path} 里找不到 .app/Info.plist")
            return 1
        payloads = {info.filename: source.read(info.filename) for info in entries}

    plist = plistlib.loads(payloads[app_plist.filename])
    before = list(plist.get("UIBackgroundModes", []))
    merged = sorted(set(before) | set(WANTED_BACKGROUND_MODES))
    if merged == before:
        print(f"= Info.plist 已有 UIBackgroundModes={before}，不需要改")
        return 0

    plist["UIBackgroundModes"] = merged
    payloads[app_plist.filename] = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)

    tmp = path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as target:
        for info in entries:
            target.writestr(info, payloads[info.filename])
    shutil.move(tmp, path)
    print(f"✓ Info.plist UIBackgroundModes {before} → {merged}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
