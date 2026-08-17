#!/usr/bin/env python3
"""Fast presentation-only bloom study over an already rendered no-glow frame."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


def smoothstep(edge0: float, edge1: float, value: np.ndarray) -> np.ndarray:
    normalized = np.clip((value - edge0) / (edge1 - edge0), 0.0, 1.0)
    return normalized * normalized * (3.0 - 2.0 * normalized)


def linearize_srgb(value: np.ndarray) -> np.ndarray:
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def encode_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return np.where(value <= 0.0031308, value * 12.92, 1.055 * value ** (1.0 / 2.4) - 0.055)


def blur_rgb(linear_rgb: np.ndarray, radius: float) -> np.ndarray:
    encoded = Image.fromarray(
        np.round(np.clip(linear_rgb, 0.0, 1.0) * 255.0).astype(np.uint8), "RGB"
    )
    blurred = encoded.filter(ImageFilter.GaussianBlur(radius=radius))
    return np.asarray(blurred, dtype=np.float32) / 255.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--max-dimension", type=int, default=1600)
    args = parser.parse_args()

    image = Image.open(args.input).convert("RGB")
    scale = min(1.0, args.max_dimension / max(image.size))
    if scale < 1.0:
        image = image.resize(
            (round(image.width * scale), round(image.height * scale)),
            Image.Resampling.LANCZOS,
        )
    srgb = np.asarray(image, dtype=np.float32) / 255.0
    linear = linearize_srgb(srgb)
    luminance = linear @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    key = smoothstep(0.35, 0.75, luminance)[..., None]
    bright = linear * key

    studies = {
        "soft": ((4.0, 12.0, 36.0), (0.55, 0.30, 0.15), 0.35),
        "balanced": ((6.0, 20.0, 60.0), (0.55, 0.30, 0.15), 0.60),
        "long": ((8.0, 28.0, 90.0), (0.50, 0.30, 0.20), 0.80),
        "balanced-soft-tail": (
            (6.0, 20.0, 60.0, 150.0),
            (0.52, 0.28, 0.14, 0.06),
            0.62,
        ),
        "long-soft-tail": (
            (8.0, 28.0, 90.0, 220.0),
            (0.47, 0.27, 0.18, 0.08),
            0.82,
        ),
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, (radii, weights, gain) in studies.items():
        bloom = np.zeros_like(linear)
        for radius, weight in zip(radii, weights, strict=True):
            bloom += blur_rgb(bright, radius) * weight
        result = encode_srgb(linear + bloom * gain)
        Image.fromarray(np.round(result * 255.0).astype(np.uint8), "RGB").save(
            args.output_dir / f"bloom-{name}.png"
        )


if __name__ == "__main__":
    main()
