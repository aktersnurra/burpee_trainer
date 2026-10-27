#!/usr/bin/env python3
"""Render the approved logo as a periodic elastic contour animation.

Run with Python 3, Pillow and NumPy:
    python3 scripts/render_burpee_loader.py

No generated keyframes: each frame samples the same original artwork through a
smooth, spatially varying displacement field. The central standing figure stays
fixed. Outputs are 192px for compact rendering at 80–160 CSS pixels.
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "priv/static/images"
SIZE = 192
FRAMES = 84
DURATION_MS = 2800
IVORY = np.array([251, 245, 232])


def smoothstep(low, high, value):
    t = np.clip((value - low) / (high - low), 0, 1)
    return t * t * (3 - 2 * t)


def displacement(phase, x, y):
    """One connected material, with a fixed central spine and quiet extremities."""
    # Coordinates are relative to the original square, not individual cutouts.
    # Fade to zero throughout the standing silhouette, including its feet.
    side = smoothstep(0.075, 0.16, np.abs(x - 0.49))
    edge = smoothstep(0.015, 0.10, x) * (1 - smoothstep(0.90, 0.99, x))
    floor = 1 - smoothstep(0.80, 0.88, y)
    crown = smoothstep(0.20, 0.43, y)
    envelope = side * edge * floor * crown
    # A travelling contour phase carries the eye down the crouch and along the
    # plank / low push-up. Subtract the phase-zero field: frame zero is original.
    travel = 5.0 * (x - 0.49) + 4.0 * (y - 0.60)
    wave = np.sin(phase - travel) + np.sin(travel)
    return (
        0.014 * envelope * np.sin(phase),
        0.022 * envelope * wave,
    )


def sample(source, x, y):
    height, width = source.shape[:2]
    sx = np.clip(x * width - 0.5, 0, width - 1)
    sy = np.clip(y * height - 0.5, 0, height - 1)
    x0, y0 = sx.astype(int), sy.astype(int)
    x1, y1 = np.minimum(x0 + 1, width - 1), np.minimum(y0 + 1, height - 1)
    fx, fy = (sx - x0)[..., None], (sy - y0)[..., None]
    return (
        source[y0, x0] * (1 - fx) * (1 - fy)
        + source[y0, x1] * fx * (1 - fy)
        + source[y1, x0] * (1 - fx) * fy
        + source[y1, x1] * fx * fy
    )


def save_gif(frames, path, durations, transparent=False):
    # One shared ivory-to-black palette avoids frame-to-frame palette flicker.
    ivory = IVORY
    palette = Image.new("P", (1, 1))
    colors = [0, 0, 0]
    for level in range(1, 256):
        colors.extend(np.rint(ivory * level / 255).astype(int).tolist())
    palette.putpalette(colors)
    indexed = []
    for frame in frames:
        rgb = frame.convert("RGB")
        item = rgb.quantize(palette=palette, dither=Image.Dither.NONE)
        if transparent:
            # GIF supports binary alpha; WebP is the smooth-alpha deliverable.
            item.paste(0, mask=frame.getchannel("A").point(lambda a: 255 if a < 128 else 0))
        indexed.append(item)
    options = {"transparency": 0, "disposal": 2} if transparent else {"disposal": 1}
    indexed[0].save(
        path, save_all=True, append_images=indexed[1:], duration=durations,
        loop=0, optimize=True, **options,
    )


def main():
    original = np.asarray(Image.open(ROOT / "docs/branding/icon-master.png").convert("RGB"))
    # Remove near-black / near-ivory raster noise; keep the original edge coverage.
    coverage = np.clip(np.max(original / IVORY, axis=2), 0, 1)
    coverage[coverage < 0.035] = 0
    coverage[coverage > 0.965] = 1
    source = coverage[..., None] * IVORY
    # Supersample the geometry before resizing for stable subpixel contours.
    render_size = SIZE * 2
    y, x = np.mgrid[:render_size, :render_size] / render_size + 0.5 / render_size
    frames = []
    for index in range(FRAMES + 1):
        # Include an identical closing frame; total playback is still 2.8 seconds.
        phase = 0.0 if index == FRAMES else 2 * np.pi * index / FRAMES
        dx, dy = displacement(phase, x, y)
        pixels = np.clip(np.rint(sample(source, x + dx, y + dy)), 0, 255).astype("uint8")
        resized = Image.fromarray(pixels).resize((SIZE, SIZE), Image.Resampling.LANCZOS)
        # 32 coverage levels retain antialiasing without costly color noise.
        alpha = np.clip(np.max(np.asarray(resized) / IVORY, axis=2), 0, 1)
        alpha = np.rint(alpha * 31) / 31
        frames.append(Image.fromarray(np.rint(alpha[..., None] * IVORY).astype("uint8")))
    assert np.array_equal(np.asarray(frames[0]), np.asarray(frames[-1]))
    # Millisecond WebP timing, and centisecond GIF timing, with no accumulated drift.
    count = len(frames)
    webp_times = [round((i + 1) * DURATION_MS / count) - round(i * DURATION_MS / count) for i in range(count)]
    gif_times = [10 * (round((i + 1) * DURATION_MS / count / 10) - round(i * DURATION_MS / count / 10)) for i in range(count)]
    frames[0].save(OUTPUT / "burpee-loader-still.png", optimize=True)
    frames[0].save(
        OUTPUT / "burpee-loader.webp", save_all=True, append_images=frames[1:],
        duration=webp_times, loop=0, lossless=True, method=6,
    )
    save_gif(frames, OUTPUT / "burpee-loader.gif", gif_times)
    # Recover coverage from the ivory foreground on black; preserve internal holes.
    transparent = []
    ivory = IVORY.astype(float)
    for frame in frames:
        pixels = np.asarray(frame).astype(float)
        alpha = np.clip(np.max(pixels / ivory, axis=2), 0, 1)
        rgba = np.empty((SIZE, SIZE, 4), dtype="uint8")
        rgba[:, :, :3] = ivory.astype("uint8")
        rgba[:, :, 3] = np.rint(alpha * 255).astype("uint8")
        transparent.append(Image.fromarray(rgba))
    transparent[0].save(
        OUTPUT / "burpee-loader-transparent.webp", save_all=True,
        append_images=transparent[1:], duration=webp_times, loop=0,
        lossless=True, method=6,
    )
    save_gif(transparent, OUTPUT / "burpee-loader-transparent.gif", gif_times, transparent=True)
    print(f"Rendered {len(frames)} frames, {DURATION_MS}ms, {SIZE} × {SIZE}px")


if __name__ == "__main__":
    main()
