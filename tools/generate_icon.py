#!/usr/bin/env python3
"""生成 pp_friend 的应用图标（Android 各密度 + adaptive icon + iOS/macOS AppIcon）。

设计：靛蓝→紫罗兰渐变底 + 白色类语音波形（5 根圆头竖条，高度不对称，
比等宽均衡器更像真实语音包络）。矢量渲染，所以 48px 下依然锐利。

用法：python3 tools/generate_icon.py
依赖：rsvg-convert（SVG→PNG）、Pillow
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
CANVAS = 1024

# 品牌色：和 App 里 ThemeData(colorSchemeSeed: #5B6ABF) 同一族
GRAD_FROM = "#8B9AF8"
GRAD_TO = "#3F4BA8"

# 波形：宽度 / 圆角 / 间距，高度不对称才像语音而不是均衡器
BAR_W = 88
BAR_GAP = 36
BAR_R = BAR_W / 2
BAR_HEIGHTS = [250, 440, 640, 430, 270]


def mark_svg(scale: float = 1.0) -> str:
    """返回波形的 SVG 片段，居中于 CANVAS，按 scale 缩放。"""
    total_w = len(BAR_HEIGHTS) * BAR_W + (len(BAR_HEIGHTS) - 1) * BAR_GAP
    start_x = (CANVAS - total_w) / 2
    cx, cy = CANVAS / 2, CANVAS / 2

    rects = []
    for i, h in enumerate(BAR_HEIGHTS):
        x = start_x + i * (BAR_W + BAR_GAP)
        y = cy - h / 2
        rects.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{BAR_W}" height="{h}" '
            f'rx="{BAR_R}" ry="{BAR_R}" fill="#ffffff"/>'
        )
    body = "\n    ".join(rects)

    if scale == 1.0:
        return body
    return (
        f'<g transform="translate({cx} {cy}) scale({scale}) '
        f'translate({-cx} {-cy})">\n    {body}\n  </g>'
    )


def full_icon_svg() -> str:
    """带底的完整图标（Android 传统图标 + iOS）。圆角由系统再裁一次也没关系。"""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="{GRAD_FROM}"/>
      <stop offset="100%" stop-color="{GRAD_TO}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.28" cy="0.18" r="0.75">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.28"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{CANVAS}" height="{CANVAS}" rx="228" ry="228" fill="url(#bg)"/>
  <rect width="{CANVAS}" height="{CANVAS}" rx="228" ry="228" fill="url(#glow)"/>
  {mark_svg(1.00)}
</svg>
"""


def foreground_svg() -> str:
    """adaptive icon 的前景层：透明底，波形缩到安全区内。

    Android 的 adaptive icon 画布是 108dp，其中只有中间 72dp 保证不被裁。
    所以前景内容要小于画布 —— 但也不能太小，0.95 时波形包围盒约占 59%，
    仍在安全区内，视觉上和周围图标的分量相当。
    """
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  {mark_svg(0.95)}
</svg>
"""


def background_svg() -> str:
    """adaptive icon 的背景层：只有渐变和光晕，铺满整张画布。"""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="{GRAD_FROM}"/>
      <stop offset="100%" stop-color="{GRAD_TO}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.28" cy="0.18" r="0.75">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.28"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#bg)"/>
  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#glow)"/>
</svg>
"""


def macos_icon_svg() -> str:
    """macOS 图标：824×824 圆角方形 + 透明边距 + 投影。

    macOS 不会像 iOS/Android 那样替应用裁圆角，图标资产本身就要带边距和
    圆角；直接拿铺满画布的 Android 图会被系统原样放大，看着比旁边的大一圈。
    """
    body = 824
    x = (CANVAS - body) / 2
    radius = 185
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="{GRAD_FROM}"/>
      <stop offset="100%" stop-color="{GRAD_TO}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.28" cy="0.18" r="0.75">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.28"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="12"
                    flood-color="#000000" flood-opacity="0.28"/>
    </filter>
  </defs>
  <rect x="{x}" y="{x}" width="{body}" height="{body}" rx="{radius}" ry="{radius}"
        fill="url(#bg)" filter="url(#shadow)"/>
  <rect x="{x}" y="{x}" width="{body}" height="{body}" rx="{radius}" ry="{radius}"
        fill="url(#glow)"/>
  <rect x="{x + 0.75}" y="{x + 0.75}" width="{body - 1.5}" height="{body - 1.5}"
        rx="{radius - 0.75}" ry="{radius - 0.75}" fill="none"
        stroke="#ffffff" stroke-opacity="0.16" stroke-width="1.5"/>
  {mark_svg(0.82)}
</svg>
"""


def render(svg: str, out: Path, size: int) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".svg")
    tmp.write_text(svg)
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(out), str(tmp)],
        check=True,
    )
    tmp.unlink()


def render_from_png(master: Path, out: Path, size: int) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(master) as im:
        im.resize((size, size), Image.LANCZOS).save(out, "PNG")


def main() -> int:
    if shutil.which("rsvg-convert") is None:
        print("缺少 rsvg-convert（brew install librsvg）", file=sys.stderr)
        return 1

    tmp_dir = ROOT / "build" / "icon_src"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    # ---- 主图（1024）----
    master_full = tmp_dir / "full_1024.png"
    master_fg = tmp_dir / "fg_1024.png"
    master_bg = tmp_dir / "bg_1024.png"
    render(full_icon_svg(), master_full, CANVAS)
    render(foreground_svg(), master_fg, CANVAS)
    render(background_svg(), master_bg, CANVAS)

    # ---- Android 传统图标 ----
    res = ROOT / "android/app/src/main/res"
    android_densities = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in android_densities.items():
        render_from_png(master_full, res / folder / "ic_launcher.png", size)

    # ---- Android adaptive icon ----
    # 前景/背景层按 108dp 画布给，xxxhdpi = 108*4 = 432
    adaptive_sizes = {
        "mipmap-mdpi": 108,
        "mipmap-hdpi": 162,
        "mipmap-xhdpi": 216,
        "mipmap-xxhdpi": 324,
        "mipmap-xxxhdpi": 432,
    }
    for folder, size in adaptive_sizes.items():
        render_from_png(master_fg, res / folder / "ic_launcher_foreground.png", size)

    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive_xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
"""
    (anydpi / "ic_launcher.xml").write_text(adaptive_xml)

    # 背景层：用位图而不是纯色，才能保住渐变和光晕
    drawable = res / "drawable"
    drawable.mkdir(parents=True, exist_ok=True)
    render_from_png(master_bg, drawable / "ic_launcher_background.png", 432)

    # ---- iOS AppIcon ----
    appicon = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((appicon / "Contents.json").read_text())
    written = 0
    for entry in contents.get("images", []):
        filename = entry.get("filename")
        if not filename:
            continue
        size_pt = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        px = round(size_pt * scale)
        render_from_png(master_full, appicon / filename, px)
        written += 1

    # ---- macOS AppIcon ----
    # 直接按目标尺寸渲染 SVG，16px 下也比从 1024 缩下来干净。
    macicon = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    mac_contents = json.loads((macicon / "Contents.json").read_text())
    mac_written = 0
    for entry in mac_contents.get("images", []):
        filename = entry.get("filename")
        if not filename:
            continue
        size_pt = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        render(macos_icon_svg(), macicon / filename, round(size_pt * scale))
        mac_written += 1

    print(f"Android 传统图标 {len(android_densities)} 个 + adaptive icon")
    print(f"iOS AppIcon {written} 个")
    print(f"macOS AppIcon {mac_written} 个")
    print(f"源图：{master_full}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
