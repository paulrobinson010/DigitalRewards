#!/usr/bin/env python3
"""Copies the app icon (Branding/app-icon.png, 1024x1024) into both asset catalogs.

Edit Branding/app-icon.svg, then from apple/:
    node Branding/render.js Branding/app-icon.svg   # SVG -> PNG (Playwright + Chromium)
    python3 tools/make_icon.py                      # PNG -> asset catalogs (needs Pillow)
"""
import json
import os
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def write_catalog(folder, platform, icon):
    iconset = os.path.join(folder, "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(iconset, exist_ok=True)
    icon.save(os.path.join(iconset, "AppIcon.png"))
    with open(os.path.join(folder, "Assets.xcassets", "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(iconset, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    # The App Store rejects icons with transparency, so flatten to RGB.
    icon = Image.open(os.path.join(HERE, "Branding", "app-icon.png")).convert("RGB").resize((1024, 1024))
    write_catalog(os.path.join(HERE, "iOS"), "ios", icon)
    write_catalog(os.path.join(HERE, "Watch"), "watchos", icon)
    print("ok")
