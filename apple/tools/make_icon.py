#!/usr/bin/env python3
"""Draws the app icon (1024x1024, no transparency) into both asset catalogs.

Run from apple/: python3 tools/make_icon.py   (needs Pillow)
"""
import json
import os
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # draw large, then downsample for smooth edges


def draw():
    s = SIZE * SCALE
    img = Image.new("RGB", (s, s))
    px = ImageDraw.Draw(img)
    top, bottom = (34, 197, 94), (13, 148, 136)  # green -> teal
    for y in range(s):
        t = y / (s - 1)
        px.line([(0, y), (s, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

    c = s / 2
    # Ring: the "minutes" dial.
    r_out, width = s * 0.34, s * 0.075
    px.ellipse([c - r_out, c - r_out, c + r_out, c + r_out], outline=(255, 255, 255), width=round(width))
    # Progress tick at the top of the dial.
    px.rounded_rectangle([c - s * 0.035, c - r_out - s * 0.11, c + s * 0.035, c - r_out + s * 0.01],
                         radius=s * 0.03, fill=(255, 255, 255))
    # Play triangle: press play to earn.
    tri = s * 0.17
    px.polygon([(c - tri * 0.75, c - tri), (c - tri * 0.75, c + tri), (c + tri * 1.05, c)], fill=(255, 255, 255))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def write_catalog(folder, platform):
    iconset = os.path.join(folder, "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(iconset, exist_ok=True)
    draw().save(os.path.join(iconset, "AppIcon.png"))
    with open(os.path.join(folder, "Assets.xcassets", "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(iconset, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    write_catalog(os.path.join(here, "iOS"), "ios")
    write_catalog(os.path.join(here, "Watch"), "watchos")
    print("ok")
