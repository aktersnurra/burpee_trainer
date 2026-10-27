#!/usr/bin/env python3
"""Export the approved illustrated burpee poses (Python 3, Pillow, NumPy)."""
from io import BytesIO
from pathlib import Path
import zipfile

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "priv/static/images"
IVORY = np.array([251, 245, 232])


def main():
    with zipfile.ZipFile(ROOT / "docs/branding/loader-poses.zip") as poses:
        frames = [
            Image.open(BytesIO(poses.read(f"{i:03}.png"))).convert("RGB").resize(
                (192, 192), Image.Resampling.LANCZOS
            )
            for i in range(19)
        ]
    frames[-1] = frames[0].copy()
    durations = [round((i + 1) * 2800 / 19) - round(i * 2800 / 19) for i in range(19)]
    gif_durations = [
        10 * (round((i + 1) * 280 / 19) - round(i * 280 / 19)) for i in range(19)
    ]
    frames[0].save(OUTPUT / "burpee-loader-still.png", optimize=True)
    frames[0].save(
        OUTPUT / "burpee-loader.webp", save_all=True, append_images=frames[1:],
        duration=durations, loop=0, lossless=True,
    )
    palette = Image.new("P", (1, 1))
    palette.putpalette([
        int(value) for level in range(256) for value in np.rint(IVORY * level / 255)
    ])
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    indexed[0].save(
        OUTPUT / "burpee-loader.gif", save_all=True, append_images=indexed[1:],
        duration=gif_durations, loop=0, optimize=True,
    )
    transparent = []
    transparent_gif = []
    for frame in frames:
        alpha = np.clip(np.max(np.asarray(frame) / IVORY, axis=2), 0, 1)
        rgba = np.empty((192, 192, 4), dtype="uint8")
        rgba[:, :, :3] = IVORY
        rgba[:, :, 3] = np.rint(alpha * 255).astype("uint8")
        transparent.append(Image.fromarray(rgba))
        item = Image.new("P", frame.size, 255)
        item.putpalette(palette.getpalette())
        item.paste(0, mask=Image.fromarray((alpha < 0.5).astype("uint8") * 255))
        transparent_gif.append(item)
    transparent[0].save(
        OUTPUT / "burpee-loader-transparent.webp", save_all=True,
        append_images=transparent[1:], duration=durations, loop=0, lossless=True,
    )
    transparent_gif[0].save(
        OUTPUT / "burpee-loader-transparent.gif", save_all=True,
        append_images=transparent_gif[1:], duration=gif_durations, loop=0,
        transparency=0, disposal=2, optimize=True,
    )


if __name__ == "__main__":
    main()
