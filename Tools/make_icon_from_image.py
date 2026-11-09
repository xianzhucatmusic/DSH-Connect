#!/usr/bin/env python3
"""从用户提供的方图生成 macOS 应用图标（AppIcon.icns + 1024 母版）。

原图是「蓝色圆形 + 白色浪花 + 粉色喵字」，白底方形。
macOS 图标规范是圆角方形（squircle），所以这里：
  1. 裁出蓝色圆
  2. 换到自定义透明画布，圆撑满圆角方形的内切圆
  3. 套 squircle 蒙版 + 投影
这样圆形图案在圆角方形里既饱满又符合系统观感。

用法: python3 Tools/make_icon_from_image.py <源图> [输出目录]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SUPER = 2
MARGIN = 88          # 圆角方形四周留白（macOS 图标网格）
CORNER = 226         # squircle 圆角半径


def dominant_blue_bounds(image: Image.Image):
    """找出图像里蓝色圆的包围盒。"""
    rgb = image.convert("RGB")
    w, h = rgb.size
    px = rgb.load()

    def is_blue(c):
        r, g, b = c
        return b > 140 and g > 130 and r < 170 and b > r

    mid_y = h // 2
    left = next((x for x in range(w) if is_blue(px[x, mid_y])), 0)
    right = next((x for x in range(w - 1, -1, -1) if is_blue(px[x, mid_y])), w - 1)
    mid_x = (left + right) // 2
    top = next((y for y in range(h) if is_blue(px[mid_x, y])), 0)
    bottom = next((y for y in range(h - 1, -1, -1) if is_blue(px[mid_x, y])), h - 1)
    return left, top, right, bottom


def build(src_path: str, out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    src = Image.open(src_path).convert("RGB")
    left, top, right, bottom = dominant_blue_bounds(src)

    # 稍微外扩一点，保留圆的抗锯齿边缘
    pad = 4
    left = max(0, left - pad)
    top = max(0, top - pad)
    right = min(src.width - 1, right + pad)
    bottom = min(src.height - 1, bottom + pad)
    circle = src.crop((left, top, right + 1, bottom + 1))
    side = max(circle.width, circle.height)
    square = Image.new("RGB", (side, side), (255, 255, 255))
    square.paste(circle, ((side - circle.width) // 2, (side - circle.height) // 2))

    W = SIZE * SUPER
    pad_px = MARGIN * SUPER
    inner = W - 2 * pad_px
    # 圆要覆盖整个圆角方形：直径放到外接正方形（≈ inner * √2），再居中
    over = int(inner * 1.415)
    over_pad = (W - over) // 2

    # 让蓝色圆直接撑满圆角方形外接正方形（越界部分由 squircle 蒙版裁掉），
    # 而不是撑满内切圆——否则四角会露出源图的白底。
    art = square.resize((over, over), Image.LANCZOS)
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    canvas.paste(art, (over_pad, over_pad))

    # squircle 蒙版
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [pad_px, pad_px, W - pad_px - 1, W - pad_px - 1],
        radius=CORNER * SUPER, fill=255)

    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    icon.paste(canvas, (0, 0), mask)
    icon = icon.resize((SIZE, SIZE), Image.LANCZOS)

    # 投影落在透明画布上
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 100), (0, 0), mask.resize((SIZE, SIZE), Image.LANCZOS))
    shadow = shadow.filter(ImageFilter.GaussianBlur(SIZE * 0.012))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, SIZE * 0.010))

    final = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    final.alpha_composite(shadow)
    final.alpha_composite(icon)
    final.save(out / "icon_1024.png")

    # iconset
    iconset = out / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        final.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        if size <= 512:
            final.resize((size * 2, size * 2), Image.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png")
    print(f"wrote {out/'icon_1024.png'} and {iconset}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    build(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "App")
