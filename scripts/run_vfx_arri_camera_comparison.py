#!/usr/bin/env python3
"""Render one reproducible ARRI/35 mm variant of the canonical iPhone scene."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--resource-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    fixture_path = arguments.fixture.expanduser().resolve()
    resource_root = arguments.resource_root.expanduser().resolve()
    output = arguments.output_dir.expanduser().resolve()
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    settings = fixture["settings"]
    iphone_distance = float(settings["SCREEN_MOIRE_DISTANCE_METERS"])
    iphone_focal_mm = 4.2
    iphone_gate_width_mm = 5.815385
    arri_focal_mm = 35.0
    arri_gate_width_mm = 27.99
    arri_distance = iphone_distance * (
        (arri_focal_mm / arri_gate_width_mm)
        / (iphone_focal_mm / iphone_gate_width_mm)
    )
    settings.update(
        {
            "SCREEN_MOIRE_CAPTURE_ID": "arri-alexa-35-open-gate",
            "SCREEN_MOIRE_LENS_ID": "generic-prime-35mm",
            "SCREEN_MOIRE_CAPTURE_WIDTH": "4608",
            "SCREEN_MOIRE_CAPTURE_HEIGHT": "3164",
            "SCREEN_MOIRE_DISTANCE_METERS": f"{arri_distance:.9f}",
            "SCREEN_MOIRE_FOCUS_DISTANCE_METERS": f"{arri_distance:.9f}",
            "SCREEN_MOIRE_F_STOP": "4",
            "SCREEN_MOIRE_SHUTTER_SECONDS": f"{1.0 / 48.0:.12f}",
            "SCREEN_MOIRE_EXPOSURE_INDEX": "800",
            "SCREEN_MOIRE_COMPUTATIONAL_EXPOSURE_COUNT": "1",
            "SCREEN_MOIRE_COMPUTATIONAL_BRACKET_SPACING_STOPS": "1",
            "SCREEN_MOIRE_BASELINE_INTERMEDIATE": "camera-rendered-acescg",
            "SCREEN_MOIRE_BASELINE_ONLY": "1",
            "SCREEN_MOIRE_SKIP_REPEAT": "1",
        }
    )
    fixture.update(
        {
            "id": "arri-alexa35-35mm-iphone-scene-quick-comparison",
            "description": (
                "Quick diagnostic: canonical iPhone scene with ARRI ALEXA 35 Open Gate, "
                "generic 35 mm prime and horizontally matched field of view."
            ),
            "status": "candidate",
            "acceptedOutput": None,
        }
    )
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="screen-arri-comparison-") as temporary:
        authored_fixture = Path(temporary) / "arri-comparison.json"
        authored_fixture.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("SCREEN_MOIRE_")
        }
        environment.update(
            {
                "SCREEN_MOIRE_FIXTURE_PATH": str(authored_fixture),
                "SCREEN_MOIRE_RESOURCE_ROOT": str(resource_root),
                "SCREEN_MOIRE_DIAGNOSTIC_DIR": str(output),
            }
        )
        completed = subprocess.run(
            [
                "swift",
                "test",
                "--filter",
                "ScreenSimulationNativeTests.optionalMoireHeadlessDiagnosticIsDeterministic()",
            ],
            cwd=repository / "apps" / "screen-native-macos",
            env=environment,
            check=False,
        )
    manifest = {
        "schema": "ScreenSimulation.VfxCameraComparison",
        "version": 1,
        "sourceFixture": str(fixture_path),
        "capture": "arri-alexa-35-open-gate",
        "lens": "generic-prime-35mm",
        "distanceMeters": arri_distance,
        "focusDistanceMeters": arri_distance,
        "fStop": 4.0,
        "shutterSeconds": 1.0 / 48.0,
        "exposureIndex": 800.0,
        "computationalExposureCount": 1,
        "output": str(output / "moire-baseline.png"),
    }
    (output / "camera-comparison.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
