#!/usr/bin/env python3
"""生成 App 图标（脚本化，不依赖设计工具）。

一版就能改：改下面的配色/形状再跑一次即可。产物写进 `scripts/icons/`，
由 `scripts/patch-ipa.py` 塞进 .app 并登记到 Info.plist 的 CFBundleIconFiles。

用法（Windows 侧，用带 Pillow 的 python）：
    python scripts/make-icon.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent / "icons"

# 配色：深炭底 + FA 那种偏橙的强调色
BG_TOP = (38, 28, 24)
BG_BOTTOM = (24, 18, 16)
ACCENT = (250, 139, 44)
ACCENT_SOFT = (255, 176, 96)
CREAM = (255, 244, 232)

# iOS 需要的尺寸（@1x/@2x/@3x 混在一起给 CFBundleIconFiles 用）
SIZES = {
    "Icon-60@2x.png": 120,
    "Icon-60@3x.png": 180,
    "Icon-76.png": 76,
    "Icon-76@2x.png": 152,
    "Icon-40@2x.png": 80,
    "Icon-40@3x.png": 120,
    "Icon-29@2x.png": 58,
    "Icon-29@3x.png": 87,
    "Icon-1024.png": 1024,
}


def vertical_gradient(size: int) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        grad.putpixel(
            (0, y),
            tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)),
        )
    return grad.resize((size, size), Image.BILINEAR)


def paw(draw: ImageDraw.ImageDraw, size: int) -> None:
    """一只爪印：主题「看图 + 兽人社区」，圆润、小尺寸下也认得出。"""
    s = size / 1024
    cx = 512 * s

    # 掌垫
    pad_w, pad_h = 300 * s, 250 * s
    pad_top = 520 * s
    draw.ellipse(
        [cx - pad_w / 2, pad_top, cx + pad_w / 2, pad_top + pad_h],
        fill=ACCENT,
    )

    # 四根脚趾：中间两根高，外侧两根低且略小
    toes = [
        (-232, 330, 92, 116),
        (-96, 262, 96, 122),
        (96, 262, 96, 122),
        (232, 330, 92, 116),
    ]
    for dx, top, w, h in toes:
        x = cx + dx * s
        draw.ellipse(
            [x - w * s / 2, top * s, x + w * s / 2, (top + h) * s],
            fill=ACCENT_SOFT,
        )


def render(size: int) -> Image.Image:
    base = vertical_gradient(size).convert("RGBA")
    draw = ImageDraw.Draw(base)

    # 一圈细橙边，放在浅色壁纸上也能分清边界
    ring = size / 1024 * 26
    draw.rounded_rectangle(
        [ring, ring, size - ring, size - ring],
        radius=size / 1024 * 210,
        outline=(*ACCENT, 90),
        width=max(1, round(size / 1024 * 10)),
    )

    paw(draw, size)
    return base.convert("RGB")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    master = render(1024)
    for name, size in SIZES.items():
        image = master if size == 1024 else master.resize((size, size), Image.LANCZOS)
        image.save(OUT / name, optimize=True)
    print(f"OK {len(SIZES)} icons -> {OUT}")


if __name__ == "__main__":
    main()
