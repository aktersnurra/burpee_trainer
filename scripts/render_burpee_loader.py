#!/usr/bin/env python3
"""Export the approved illustrated burpee poses (Python 3, Pillow, NumPy).

The poses are ivory figures on black. The app is light-only, so the exports invert
them: a dark ink silhouette on a transparent background.
"""
from io import BytesIO
from pathlib import Path
import zipfile

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "priv/static/images"
IVORY = np.array([251, 245, 232])
INK = np.array([32, 32, 29])  # base-content #20201D
STONE = np.array([244, 242, 238])  # base-100 #F4F2EE, the GIF's edge matte
SIZE = 192


def alpha_of(frame):
    """How much of the figure each pixel holds: ivory is 1, black is 0."""
    return np.clip(np.max(np.asarray(frame) / IVORY, axis=2), 0, 1)


def ink_rgba(frame):
    rgba = np.empty((SIZE, SIZE, 4), dtype="uint8")
    rgba[:, :, :3] = INK
    rgba[:, :, 3] = np.rint(alpha_of(frame) * 255).astype("uint8")
    return Image.fromarray(rgba)


def main():
    with zipfile.ZipFile(ROOT / "docs/branding/loader-poses.zip") as poses:
        frames = [
            Image.open(BytesIO(poses.read(f"{i:03}.png"))).convert("RGB").resize(
                (SIZE, SIZE), Image.Resampling.LANCZOS
            )
            for i in range(19)
        ]
    frames[-1] = frames[0].copy()
    durations = [round((i + 1) * 2800 / 19) - round(i * 2800 / 19) for i in range(19)]
    gif_durations = [
        10 * (round((i + 1) * 280 / 19) - round(i * 280 / 19)) for i in range(19)
    ]

    rgba = [ink_rgba(frame) for frame in frames]
    rgba[0].save(OUTPUT / "burpee-loader-still.png", optimize=True)
    rgba[0].save(
        OUTPUT / "burpee-loader.webp", save_all=True, append_images=rgba[1:],
        duration=durations, loop=0, lossless=True,
    )

    # One shared palette keeps the GIF from flickering between frames.
    sheet = np.concatenate(
        [np.rint(STONE * (1 - alpha_of(f)[:, :, None]) + INK * alpha_of(f)[:, :, None])
         .astype("uint8") for f in frames], axis=0,
    )
    shared = Image.fromarray(sheet).quantize(
        colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE
    )
    palette = (shared.getpalette() or [])[: 255 * 3]
    palette += [0] * (768 - len(palette))
    gif = []
    for frame in frames:
        alpha = alpha_of(frame)
        flat = np.rint(
            STONE * (1 - alpha[:, :, None]) + INK * alpha[:, :, None]
        ).astype("uint8")
        indexed = np.asarray(
            Image.fromarray(flat).quantize(palette=shared, dither=Image.Dither.NONE)
        ).copy()
        indexed[alpha < 0.5] = 255
        item = Image.fromarray(indexed, mode="P")
        item.putpalette(palette)
        gif.append(item)
    gif[0].save(
        OUTPUT / "burpee-loader.gif", save_all=True, append_images=gif[1:],
        duration=gif_durations, loop=0, transparency=255, disposal=2, optimize=False,
    )


if __name__ == "__main__":
    main()
