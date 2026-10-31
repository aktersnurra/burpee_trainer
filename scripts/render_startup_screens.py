#!/usr/bin/env python3
"""Export the iPhone launch images (Python 3, Pillow): the app icon on the stone background."""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "priv/static/images/startup"
STONE = (244, 242, 238)  # base-100 #F4F2EE
SCREENS = [
    (1125, 2436), (1170, 2532), (1179, 2556), (1206, 2622), (1242, 2688),
    (1260, 2736), (1284, 2778), (1290, 2796), (1320, 2868), (750, 1334), (828, 1792),
]
TILE = 0.30  # icon width as a share of the screen width
CORNER = 0.2237  # iOS icon corner radius as a share of the tile


def main():
    icon = Image.open(ROOT / "docs/branding/icon-1024.png").convert("RGB")
    for width, height in SCREENS:
        side = round(width * TILE)
        tile = icon.resize((side, side), Image.Resampling.LANCZOS)
        mask = Image.new("L", (side * 4, side * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, side * 4 - 1, side * 4 - 1), radius=side * 4 * CORNER, fill=255
        )
        mask = mask.resize((side, side), Image.Resampling.LANCZOS)
        screen = Image.new("RGB", (width, height), STONE)
        # Optically centred: a touch above the middle, where the app's content starts.
        screen.paste(tile, ((width - side) // 2, (height - side) // 2 - round(height * 0.02)), mask)
        screen.save(OUTPUT / f"iphone-{width}x{height}.png", optimize=True)


if __name__ == "__main__":
    main()
