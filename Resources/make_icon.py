#!/usr/bin/env python3
"""
Generates Resources/AppIcon.icns for UpdateScout.

Draws a macOS-style squircle with a gradient field and a downward arrow
resolving into a baseline — "something new has landed". Writes a real .icns
by packing PNGs directly, so it does not need macOS `iconutil` and can be
regenerated on any machine with Pillow.

    pip install pillow
    python3 Resources/make_icon.py
"""

import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE / "AppIcon.icns"

# Rendered large, then downsampled — cheaper than hinting each size by hand.
S = 1024

TOP = (56, 132, 255)      # blue
BOTTOM = (28, 196, 154)   # green
GLYPH = (255, 255, 255)


def squircle_mask(size, radius_ratio=0.2237):
    """Apple's icon silhouette is close enough to a large-radius rounded rect."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    inset = int(size * 0.0977)  # icon art sits inside a transparent margin
    draw.rounded_rectangle(
        [inset, inset, size - inset - 1, size - inset - 1],
        radius=r,
        fill=255,
    )
    return mask


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        grad.putpixel(
            (0, y),
            (
                round(top[0] + (bottom[0] - top[0]) * t),
                round(top[1] + (bottom[1] - top[1]) * t),
                round(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return grad.resize((size, size), Image.BILINEAR)


def build_master():
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = squircle_mask(S)

    field = vertical_gradient(S, TOP, BOTTOM).convert("RGBA")

    # Soft highlight sweep across the upper third, so the face isn't flat.
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse(
        [-S * 0.35, -S * 0.75, S * 1.05, S * 0.42], fill=64
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(S * 0.05))
    field = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)), field, sheen)

    base.paste(field, (0, 0), mask)

    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(glyph)

    cx = S / 2
    stem_w = S * 0.076
    stem_top = S * 0.272
    stem_bottom = S * 0.548

    # Arrow shaft.
    d.rounded_rectangle(
        [cx - stem_w / 2, stem_top, cx + stem_w / 2, stem_bottom],
        radius=stem_w / 2,
        fill=GLYPH,
    )

    # Arrow head — a chevron built from two rounded strokes.
    head_half = S * 0.132
    head_y = stem_bottom
    head_top = head_y - head_half
    d.line(
        [(cx - head_half, head_top), (cx, head_y)],
        fill=GLYPH, width=int(stem_w), joint="curve",
    )
    d.line(
        [(cx + head_half, head_top), (cx, head_y)],
        fill=GLYPH, width=int(stem_w), joint="curve",
    )
    # Round the three stroke ends the line primitive leaves square.
    for px, py in ((cx - head_half, head_top), (cx + head_half, head_top), (cx, head_y)):
        d.ellipse(
            [px - stem_w / 2, py - stem_w / 2, px + stem_w / 2, py + stem_w / 2],
            fill=GLYPH,
        )

    # Baseline the arrow lands on.
    tray_half = S * 0.196
    tray_y = S * 0.668
    d.rounded_rectangle(
        [cx - tray_half, tray_y, cx + tray_half, tray_y + stem_w],
        radius=stem_w / 2,
        fill=GLYPH,
    )

    base = Image.alpha_composite(base, glyph)
    return base


# (icns chunk type, pixel size) — the modern PNG-based entries.
VARIANTS = [
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
    (b"ic11", 32),
    (b"ic12", 64),
    (b"ic13", 256),
    (b"ic14", 512),
]


def write_icns(master, path):
    chunks = b""
    for code, size in VARIANTS:
        scaled = master.resize((size, size), Image.LANCZOS)
        from io import BytesIO

        buf = BytesIO()
        scaled.save(buf, format="PNG")
        payload = buf.getvalue()
        chunks += code + struct.pack(">I", len(payload) + 8) + payload

    path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


if __name__ == "__main__":
    master = build_master()
    master.save(HERE / "AppIcon-1024.png")
    write_icns(master, OUT)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
