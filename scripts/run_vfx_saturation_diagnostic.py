#!/usr/bin/env python3
"""Isolate Lens→Bayer/Develop chroma loss with one strict VFX fixture."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


VARIANT_RE = re.compile(
    r"MOIRE_VARIANT name=baseline hash=(?P<hash>[0-9a-f]+) "
    r"meanChroma=(?P<mean>[^ ]+) p95Chroma=(?P<p95>[^ ]+) "
    r"metalSubmitToResultMs=(?P<milliseconds>[^\s]+)"
)


def existing_directory(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise argparse.ArgumentTypeError(f"No es un directorio: {path}")
    return path


def run_variant(
    *,
    repository: Path,
    native: Path,
    fixture: dict,
    fixture_directory: Path,
    resource_root: Path,
    output_root: Path,
    name: str,
    intermediate: str,
    output_transform: str,
    ideal_full_rgb: bool = False,
) -> dict:
    output = output_root / name
    cached_result = output / "diagnostic-result.json"
    if cached_result.is_file():
        return json.loads(cached_result.read_text(encoding="utf-8"))
    authored = json.loads(json.dumps(fixture))
    authored["id"] = f"{fixture['id']}-saturation-{name}"
    authored["description"] = (
        f"Diagnostic only: {intermediate} through {output_transform}; "
        "does not replace the canonical fixture."
    )
    authored["status"] = "candidate"
    authored["acceptedOutput"] = None
    authored["settings"]["SCREEN_MOIRE_BASELINE_INTERMEDIATE"] = intermediate
    authored["settings"]["SCREEN_MOIRE_OUTPUT_TRANSFORM_ID"] = output_transform
    authored["settings"]["SCREEN_MOIRE_BASELINE_ONLY"] = "1"
    authored["settings"]["SCREEN_MOIRE_SKIP_REPEAT"] = "1"
    fixture_path = fixture_directory / f"{name}.json"
    fixture_path.write_text(json.dumps(authored, indent=2) + "\n", encoding="utf-8")
    output.mkdir(parents=True)
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("SCREEN_MOIRE_") and not key.startswith("SCREEN_DIAGNOSTIC_")
    }
    environment.update(
        {
            "SCREEN_MOIRE_FIXTURE_PATH": str(fixture_path),
            "SCREEN_MOIRE_RESOURCE_ROOT": str(resource_root),
            "SCREEN_MOIRE_DIAGNOSTIC_DIR": str(output),
        }
    )
    if ideal_full_rgb:
        environment["SCREEN_MOIRE_DIAGNOSTIC_IDEAL_FULL_RGB"] = "1"
    completed = subprocess.run(
        [
            "swift",
            "test",
            "--filter",
            "ScreenSimulationNativeTests.optionalMoireHeadlessDiagnosticIsDeterministic()",
        ],
        cwd=native,
        env=environment,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(completed.stdout, end="")
    if completed.returncode != 0:
        raise RuntimeError(f"Falló el render {name} con código {completed.returncode}")
    match = VARIANT_RE.search(completed.stdout)
    if match is None:
        raise RuntimeError(f"No se encontraron métricas para {name}")
    resolved = json.loads((output / "resolved-settings.json").read_text(encoding="utf-8"))
    result = {
        "name": name,
        "intermediate": intermediate,
        "outputTransform": output_transform,
        "width": resolved["render"]["width"],
        "height": resolved["render"]["height"],
        "pixelRGBA8SHA256": match.group("hash"),
        "meanChroma": float(match.group("mean")),
        "p95Chroma": float(match.group("p95")),
        "metalSubmitToResultMilliseconds": float(match.group("milliseconds")),
        "png16": str(output / "moire-baseline.png"),
    }
    cached_result.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--resource-root", required=True, type=existing_directory)
    parser.add_argument("--output-dir", required=True, type=Path)
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    fixture_path = arguments.fixture.expanduser()
    if not fixture_path.is_absolute():
        fixture_path = repository / fixture_path
    fixture_path = fixture_path.resolve()
    if not fixture_path.is_file():
        parser.error(f"No existe el fixture: {fixture_path}")
    output = arguments.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    native = repository / "apps" / "screen-native-macos"
    build_environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("SCREEN_MOIRE_") and not key.startswith("SCREEN_DIAGNOSTIC_")
    }
    subprocess.run(
        ["cargo", "build", "-p", "screen-native-bridge", "--release"],
        cwd=repository,
        env=build_environment,
        check=True,
    )
    subprocess.run(["swift", "package", "clean"], cwd=native, env=build_environment, check=True)
    variants = [
        ("ideal-full-rgb-odt", "lens-projection", "aces2-srgb-sdr-100", True),
        ("developed-odt", "developed-acescg", "aces2-srgb-sdr-100", False),
        ("ideal-full-rgb-p3-odt", "lens-projection", "aces2-display-p3-sdr-100", True),
        ("developed-p3-odt", "developed-acescg", "aces2-display-p3-sdr-100", False),
        (
            "developed-untone-mapped-srgb",
            "developed-acescg",
            "diagnostic-untone-mapped-srgb",
            False,
        ),
    ]
    with tempfile.TemporaryDirectory(prefix="screen-saturation-fixtures-") as temporary:
        results = [
            run_variant(
                repository=repository,
                native=native,
                fixture=fixture,
                fixture_directory=Path(temporary),
                resource_root=arguments.resource_root,
                output_root=output,
                name=name,
                intermediate=intermediate,
                output_transform=transform,
                ideal_full_rgb=ideal,
            )
            for name, intermediate, transform, ideal in variants
        ]
    by_name = {result["name"]: result for result in results}
    summary = {
        "schema": "ScreenSimulation.VfxSaturationDiagnostic",
        "version": 1,
        "sourceFixture": str(fixture_path),
        "interpretation": (
            "Ideal full RGB applies the canonical shutter, radiometric calibration and Develop "
            "scale to Lens while omitting only CFA/demosaic. Developed uses the canonical Bayer "
            "route. Both have the same 5712x4284 raster and Preview ODT. The additional "
            "Developed un-tone-mapped sRGB view isolates chromaticity changes introduced by "
            "the ACES 2.0 SDR output transform; it is diagnostic-only and never authored."
        ),
        "variants": results,
        "ratios": {
            "odtMeanChromaDevelopedOverIdealFullRGB": (
                by_name["developed-odt"]["meanChroma"]
                / by_name["ideal-full-rgb-odt"]["meanChroma"]
            ),
            "odtP95ChromaDevelopedOverIdealFullRGB": (
                by_name["developed-odt"]["p95Chroma"]
                / by_name["ideal-full-rgb-odt"]["p95Chroma"]
            ),
        },
    }
    runtime = Path(
        "/Users/jorgetorrenslage/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
    )
    metric_script = repository / "scripts" / "summarize_vfx_saturation.py"
    summary_path = output / "saturation-diagnostic.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    if runtime.is_file() and metric_script.is_file():
        subprocess.run([str(runtime), str(metric_script), str(output)], check=True)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
