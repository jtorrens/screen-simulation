#!/usr/bin/env python3
"""Summarize the two like-for-like PNGs emitted by the saturation diagnostic."""

from __future__ import annotations

import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image


def main() -> int:
    root = Path(sys.argv[1]).resolve()
    ideal = np.asarray(
        Image.open(root / "ideal-full-rgb-odt" / "moire-baseline.png").convert("RGB"),
        dtype=np.float32,
    ) / 255.0
    developed = np.asarray(
        Image.open(root / "developed-odt" / "moire-baseline.png").convert("RGB"),
        dtype=np.float32,
    ) / 255.0
    if ideal.shape != developed.shape:
        raise RuntimeError("Los dos rasters de saturación no tienen las mismas dimensiones")
    ideal_chroma = ideal.max(axis=2) - ideal.min(axis=2)
    developed_chroma = developed.max(axis=2) - developed.min(axis=2)
    luminance = ideal @ np.asarray([0.2126, 0.7152, 0.0722], dtype=np.float32)
    colored = (ideal_chroma > 0.05) & (luminance > 0.02) & (luminance < 0.98)
    cyan = (
        (ideal[:, :, 1] > ideal[:, :, 0] + 0.03)
        & (ideal[:, :, 2] > ideal[:, :, 0] + 0.03)
        & (luminance > 0.05)
    )
    absolute = np.abs(ideal - developed)
    ideal_relative_chroma = ideal_chroma / np.maximum(ideal.max(axis=2), 1.0 / 255.0)
    developed_relative_chroma = developed_chroma / np.maximum(
        developed.max(axis=2), 1.0 / 255.0
    )
    difference = np.clip(absolute * 8.0, 0.0, 1.0)
    Image.fromarray((difference * 255.0).astype(np.uint8)).save(root / "difference-8x.png")
    document_path = root / "saturation-diagnostic.json"
    document = json.loads(document_path.read_text(encoding="utf-8"))
    document["maskedMetrics"] = {
        "visibleColoredPixelsChromaThreshold0p05": {
            "pixelCount": int(colored.sum()),
            "idealMeanChroma": float(ideal_chroma[colored].mean()),
            "developedMeanChroma": float(developed_chroma[colored].mean()),
            "developedOverIdeal": float(
                developed_chroma[colored].mean() / ideal_chroma[colored].mean()
            ),
        },
        "cyanPixels": {
            "pixelCount": int(cyan.sum()),
            "idealMeanChroma": float(ideal_chroma[cyan].mean()),
            "developedMeanChroma": float(developed_chroma[cyan].mean()),
            "developedOverIdeal": float(
                developed_chroma[cyan].mean() / ideal_chroma[cyan].mean()
            ),
        },
        "meanAbsoluteRGB8Normalized": float(absolute.mean()),
        "p99AbsoluteRGB8Normalized": float(np.quantile(absolute, 0.99)),
        "visibleColoredPixelsRelativeChroma": {
            "idealMean": float(ideal_relative_chroma[colored].mean()),
            "developedMean": float(developed_relative_chroma[colored].mean()),
            "developedOverIdeal": float(
                developed_relative_chroma[colored].mean()
                / ideal_relative_chroma[colored].mean()
            ),
        },
    }
    document_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
