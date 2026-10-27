#!/usr/bin/env python3
"""Render a side-profile silhouette performing one six-count military burpee.

Requires Python 3, Pillow and NumPy. Run from any directory. Hands and toes
stay planted during the push-up; no jump, clap, or whole-image movement.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "priv/static/images"
SIZE, FRAMES, DURATION_MS = 192, 84, 2800
IVORY = np.array([251, 245, 232])

# Shoulder, hip, elbow, wrist, knee, ankle, toe on a fixed 256-unit canvas.
STAND = np.array([[128, 82], [122, 141], [138, 112], [136, 145],
                  [124, 179], [123, 213], [137, 220]], dtype=float)
CROUCH = np.array([[177, 156], [119, 173], [181, 187], [185, 218],
                   [145, 190], [121, 212], [136, 220]], dtype=float)
PLANK = np.array([[186, 163], [130, 177], [185, 190], [185, 218],
                  [90, 187], [52, 198], [41, 220]], dtype=float)
LOW = np.array([[184, 196], [128, 201], [157, 197], [185, 218],
                [88, 205], [50, 209], [41, 220]], dtype=float)
KEYFRAMES = [(0, STAND), (0.10, STAND), (0.62, CROUCH), (0.98, PLANK),
             (1.40, LOW), (1.82, PLANK), (2.16, CROUCH), (2.70, STAND), (2.80, STAND)]


def pose_at(seconds):
    for (start, a), (end, b) in zip(KEYFRAMES, KEYFRAMES[1:]):
        if seconds <= end:
            u = np.clip((seconds - start) / (end - start), 0, 1)
            pose = a + (b - a) * (u * u * (3 - 2 * u))
            if start in (0.62, 1.82):
                # Feet leave the floor for the kick-back / tuck; hands stay fixed.
                pose[5:, 1] -= 13 * np.sin(np.pi * u)
            return pose
    return STAND.copy()


def smooth_outline(points):
    points = np.asarray(points, dtype=float)
    result = []
    for i in range(len(points)):
        p0, p1, p2, p3 = (points[j % len(points)] for j in (i - 1, i, i + 1, i + 2))
        for t in np.linspace(0, 1, 12, endpoint=False):
            result.append(0.5 * (2 * p1 + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return np.asarray(result)


def draw_pose(pose):
    factor = SIZE * 4 / 256
    image = Image.new("L", (SIZE * 4, SIZE * 4), 0)
    draw = ImageDraw.Draw(image)

    def polygon(points):
        draw.polygon([tuple(p * factor) for p in points], fill=255)

    def disk(center, radius):
        x, y = center * factor
        r = radius * factor
        draw.ellipse((x - r, y - r, x + r, y + r), fill=255)

    def bone(a, b, wa, wb):
        direction = b - a
        normal = np.array([-direction[1], direction[0]]) / np.linalg.norm(direction)
        polygon(np.array([a + normal * wa, b + normal * wb,
                          b - normal * wb, a - normal * wa]))
        disk(a, wa)
        disk(b, wb)

    shoulder, hip, elbow, wrist, knee, ankle, toe = pose
    forward = shoulder - hip
    forward /= np.linalg.norm(forward)
    front = np.array([-forward[1], forward[0]])
    standing = np.clip((163 - shoulder[1]) / 81, 0, 1)
    far_offset = np.array([-9 * standing, -2 * (1 - standing)])
    bone(hip + far_offset * 0.4, knee + far_offset, 7, 5)
    bone(knee + far_offset, ankle + far_offset, 5, 3.4)
    bone(ankle + far_offset, toe + far_offset, 3.4, 3)
    length = np.linalg.norm(shoulder - hip)
    outline = [
        shoulder + forward * 4 - front * 7,
        shoulder - forward * length * 0.18 - front * 10,
        hip + forward * length * 0.33 - front * 8,
        hip - front * 10,
        hip - forward * 7 + front * 5,
        hip + front * 11,
        shoulder - forward * length * 0.32 + front * 11,
        shoulder + front * 9,
    ]
    polygon(smooth_outline(outline))
    bone(hip, knee, 8, 5.5)
    bone(knee, ankle, 5.5, 3.6)
    bone(ankle, toe, 3.6, 3)
    bone(shoulder + np.array([-3, -1]), elbow + np.array([-3, -1]), 4.5, 3.7)
    bone(elbow + np.array([-3, -1]), wrist + np.array([-3, 0]), 3.7, 2.7)
    bone(shoulder, elbow, 5, 4)
    bone(elbow, wrist, 4, 2.9)
    planted = np.clip((wrist[1] - 200) / 18, 0, 1)
    hand_direction = wrist - elbow
    hand_direction /= np.linalg.norm(hand_direction)
    fingers = wrist + hand_direction * 6 * (1 - planted) + np.array([10, 1]) * planted
    bone(wrist, fingers, 3, 2.3)
    bone(shoulder, shoulder + forward * 15, 5, 4.5)
    head = [(-7, 12), (-10, 17), (-11, 27), (-8, 35), (-2, 39),
            (5, 38), (10, 34), (11, 27), (10, 23), (13, 20),
            (11, 18), (10, 13), (6, 11), (3, 8), (-4, 8)]
    polygon(smooth_outline([shoulder + front * x + forward * y for x, y in head]))
    mask = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    alpha = np.rint(np.asarray(mask) / 255 * 31) / 31
    return Image.fromarray(np.rint(alpha[..., None] * IVORY).astype("uint8"))


def save_gif(frames, path, durations, transparent=False):
    palette = Image.new("P", (1, 1))
    colors = [0, 0, 0]
    for level in range(1, 256):
        colors.extend(np.rint(IVORY * level / 255).astype(int).tolist())
    palette.putpalette(colors)
    indexed = []
    for frame in frames:
        item = frame.convert("RGB").quantize(palette=palette, dither=Image.Dither.NONE)
        if transparent:
            item.paste(0, mask=frame.getchannel("A").point(lambda a: 255 if a < 128 else 0))
        indexed.append(item)
    options = {"transparency": 0, "disposal": 2} if transparent else {"disposal": 1}
    indexed[0].save(path, save_all=True, append_images=indexed[1:], duration=durations,
                    loop=0, optimize=True, **options)


def main():
    frames = [draw_pose(pose_at(i * DURATION_MS / 1000 / FRAMES)) for i in range(FRAMES + 1)]
    assert np.array_equal(np.asarray(frames[0]), np.asarray(frames[-1]))
    count = len(frames)
    webp_times = [round((i + 1) * DURATION_MS / count) - round(i * DURATION_MS / count)
                 for i in range(count)]
    gif_times = [10 * (round((i + 1) * DURATION_MS / count / 10)
                      - round(i * DURATION_MS / count / 10)) for i in range(count)]
    frames[0].save(OUTPUT / "burpee-loader-still.png", optimize=True)
    frames[0].save(OUTPUT / "burpee-loader.webp", save_all=True, append_images=frames[1:],
                   duration=webp_times, loop=0, lossless=True, method=6)
    save_gif(frames, OUTPUT / "burpee-loader.gif", gif_times)
    transparent = []
    for frame in frames:
        alpha = np.clip(np.max(np.asarray(frame) / IVORY, axis=2), 0, 1)
        rgba = np.empty((SIZE, SIZE, 4), dtype="uint8")
        rgba[:, :, :3] = IVORY
        rgba[:, :, 3] = np.rint(alpha * 255).astype("uint8")
        transparent.append(Image.fromarray(rgba))
    transparent[0].save(OUTPUT / "burpee-loader-transparent.webp", save_all=True,
        append_images=transparent[1:], duration=webp_times, loop=0, lossless=True, method=6)
    save_gif(transparent, OUTPUT / "burpee-loader-transparent.gif", gif_times, transparent=True)
    print(f"Rendered one six-count rep: {DURATION_MS}ms, {SIZE} × {SIZE}px")


if __name__ == "__main__":
    main()
