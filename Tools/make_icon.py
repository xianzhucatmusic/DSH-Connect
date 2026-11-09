#!/usr/bin/env python3
"""Render the QwenServing app icon (macOS style: rounded squircle + drop shadow).

Usage: python3 Tools/make_icon.py [out-dir]
Produces 1024px master PNG plus AppIcon.iconset for iconutil.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024                      # master canvas
SUPER = 4                     # supersample factor for geometry
W = S * SUPER
MARGIN = 92                   # transparent padding around the squircle (Apple grid)
CORNER = 226                  # macOS squircle-ish corner radius

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__)) + "/../App"


def squircle_mask(width, corner, pad):
    """Rounded-rect mask, drawn at supersample then downscaled (anti-aliased)."""
    m = Image.new("L", (width, width), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(
        [pad, pad, width - pad - 1, width - pad - 1],
        radius=corner, fill=255,
    )
    return m


def vertical_gradient(width, top, bottom):
    g = Image.new("RGB", (1, width))
    for y in range(width):
        t = y / (width - 1)
        # ease-out so the glow sits mostly behind the glyph
        t = t ** 0.85
        g.putpixel((0, y), tuple(int(round(top[i] + (bottom[i] - top[i]) * t)) for i in range(3)))
    return g.resize((width, width), Image.BILINEAR)


def radial_glow(width, center, radius, color, strength=255):
    """Soft radial highlight layer (RGBA)."""
    small = 256
    layer = Image.new("L", (small, small), 0)
    px = layer.load()
    cx, cy = center[0] / width * small, center[1] / width * small
    r = radius / width * small
    for y in range(small):
        for x in range(small):
            d = math.hypot(x - cx, y - cy)
            if d < r:
                v = (1 - d / r) ** 2.2
                px[x, y] = int(255 * v * strength / 255)
    layer = layer.resize((width, width), Image.BICUBIC)
    out = Image.new("RGBA", (width, width), color + (0,))
    out.putalpha(layer)
    return out


def load_font(size, bold=True, condensed=False):
    candidates = []
    if condensed:
        candidates += [
            "/System/Library/Fonts/Avenir Next Condensed.ttc",
            "/System/Library/Fonts/Avenir Next.ttc",
        ]
    candidates += [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        if not os.path.exists(path):
            continue
        for index in (8, 6, 4, 2, 1, 0):
            try:
                f = ImageFont.truetype(path, size, index=index)
                name = (f.getname()[1] or "").lower()
                if bold and ("bold" in name or "heavy" in name or "black" in name):
                    return f
                if not bold and ("regular" in name or "medium" in name):
                    return f
            except Exception:
                continue
        try:
            return ImageFont.truetype(path, size, index=0)
        except Exception:
            continue
    return ImageFont.load_default()


def draw_ring(draw, box, color, width):
    draw.ellipse(box, outline=color, width=width)


def main():
    os.makedirs(OUT, exist_ok=True)

    # ---------- background ----------
    inside = W - 2 * (MARGIN * SUPER)
    bg = vertical_gradient(inside, (45, 128, 250), (10, 20, 58)).convert("RGBA")
    bg = bg.resize((W, W), Image.BICUBIC)

    # soft top-left light + bottom-right depth
    bg.alpha_composite(radial_glow(W, (W * 0.26, W * 0.16), W * 0.58, (170, 220, 255), 175))
    bg.alpha_composite(radial_glow(W, (W * 0.86, W * 0.92), W * 0.55, (5, 12, 30), 120))

    # ---------- orbit rings (network: local + LAN) ----------
    ring_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring_layer)
    cx = cy = W / 2
    for r, alpha, wdt in ((W * 0.315, 46, int(W * 0.008)),
                          (W * 0.415, 26, int(W * 0.006))):
        rd.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(190, 225, 255, alpha), width=wdt)
    bg.alpha_composite(ring_layer)

    # ---------- glyph: geometric "Q" ----------
    glyph = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glyph)
    ring_r = W * 0.195
    ring_w = int(W * 0.052)
    box = [cx - ring_r, cy - ring_r - W * 0.012, cx + ring_r, cy + ring_r - W * 0.012]

    # shadow under the glyph
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse([box[0] + W * 0.004, box[1] + W * 0.010, box[2] + W * 0.004, box[3] + W * 0.010],
               outline=(8, 18, 40, 150), width=ring_w)
    shadow = shadow.filter(ImageFilter.GaussianBlur(W * 0.012))
    glyph.alpha_composite(shadow)

    # white ring
    gd.ellipse(box, outline=(255, 255, 255, 255), width=ring_w)

    # tail: a tapered wedge leaving the ring at ~45 degrees (drawn as a polygon)
    ring_cy = cy - W * 0.012
    ang = math.radians(52)
    ux, uy = math.cos(ang), math.sin(ang)          # along the tail
    nx, ny = -uy, ux                               # normal to it
    # start just inside the ring so the wedge merges with it
    sx = cx + ux * ring_r * 0.88
    sy = ring_cy + uy * ring_r * 0.88
    tip_len = W * 0.150
    half_start = ring_w * 0.72
    half_end = ring_w * 0.30
    ex, ey = sx + ux * tip_len, sy + uy * tip_len
    gd.polygon([
        (sx + nx * half_start, sy + ny * half_start),
        (ex + nx * half_end, ey + ny * half_end),
        (ex - nx * half_end, ey - ny * half_end),
        (sx - nx * half_start, sy - ny * half_start),
    ], fill=(255, 255, 255, 255))
    # rounded cap
    rad = half_end
    gd.ellipse([ex - rad, ey - rad, ex + rad, ey + rad], fill=(255, 255, 255, 255))

    bg.alpha_composite(glyph)

    # ---------- mask + squircle ----------
    mask = squircle_mask(W, CORNER * SUPER, MARGIN * SUPER)
    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), mask)  # mask is full W×W
    icon = icon.resize((S, S), Image.LANCZOS)

    # ---------- drop shadow on the transparent canvas ----------
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh.paste((0, 0, 0, 110), (0, 0), mask.resize((S, S), Image.LANCZOS))
    sh = sh.filter(ImageFilter.GaussianBlur(S * 0.012))
    sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, S * 0.012))
    canvas.alpha_composite(sh)
    canvas.alpha_composite(icon)

    master = os.path.join(OUT, "icon_1024.png")
    canvas.save(master)

    # ---------- .icns ----------
    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        img = canvas.resize((size, size), Image.LANCZOS)
        img.save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        if size <= 512:
            img2 = canvas.resize((size * 2, size * 2), Image.LANCZOS)
            img2.save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    print("wrote", master, "and", iconset)


if __name__ == "__main__":
    main()
