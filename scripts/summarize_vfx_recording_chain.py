#!/usr/bin/env python3
"""Measure like-for-like Display P3 checkpoints in the recording-chain diagnostic."""

from __future__ import annotations

import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image


def load(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def main() -> int:
    root = Path(sys.argv[1]).resolve()
    camera = load(root / "camera-intent-display-p3.png")
    output = load(root / "recording-output-display-p3.png")
    codec = load(root / "recording-codec-display-p3.png")
    if camera.shape != output.shape or output.shape != codec.shape:
        raise RuntimeError("Recording checkpoints have different rasters")
    chroma = lambda image: image.max(axis=2) - image.min(axis=2)
    output_chroma = chroma(output)
    codec_chroma = chroma(codec)
    luminance = output @ np.asarray([0.22897, 0.69174, 0.07929], dtype=np.float32)
    colored = (output_chroma > 0.05) & (luminance > 0.02) & (luminance < 0.98)
    cyan = (
        colored
        & (output[:, :, 1] > output[:, :, 0] + 0.03)
        & (output[:, :, 2] > output[:, :, 0] + 0.03)
    )
    document_path = root / "recording-chain-diagnostic.json"
    document = json.loads(document_path.read_text(encoding="utf-8"))
    document["metrics"] = {
        "cameraIntentP3VersusRecordingOutputMeanAbsoluteRGB": float(
            np.abs(camera - output).mean()
        ),
        "recordingOutputVersusCodecMeanAbsoluteRGB": float(np.abs(output - codec).mean()),
        "visibleColoredPixels": {
            "pixelCount": int(colored.sum()),
            "beforeMeanChroma": float(output_chroma[colored].mean()),
            "afterMeanChroma": float(codec_chroma[colored].mean()),
            "afterOverBefore": float(
                codec_chroma[colored].mean() / output_chroma[colored].mean()
            ),
        },
        "cyanPixels": {
            "pixelCount": int(cyan.sum()),
            "beforeMeanChroma": float(output_chroma[cyan].mean()),
            "afterMeanChroma": float(codec_chroma[cyan].mean()),
            "afterOverBefore": float(
                codec_chroma[cyan].mean() / output_chroma[cyan].mean()
            ),
        },
    }
    document_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
