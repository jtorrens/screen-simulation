#!/usr/bin/env python3
"""Run one strict VFX reference fixture through the native Metal diagnostic."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys


def required_directory(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise argparse.ArgumentTypeError(f"No es un directorio: {path}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--resource-root", required=True, type=required_directory)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--settings-document",
        type=Path,
        help="Usa un ScreenSimulation.FrameSettings actual en vez de reconstruir ajustes desde el fixture.",
    )
    parser.add_argument(
        "--lens-evaluation-model",
        choices=("thin-lens", "vfx-2d-dof"),
        help="Sobrescribe explícitamente sólo el evaluador de lente del documento de ajustes.",
    )
    parser.add_argument(
        "--moire-intensity",
        type=float,
        help="Sobrescribe explícitamente la intensidad de moiré del documento de ajustes.",
    )
    parser.add_argument(
        "--ideal-full-rgb",
        action="store_true",
        help="Sustituye CFA/RAW por el control RGB ideal después de Lens Projection.",
    )
    parser.add_argument(
        "--baseline-intermediate",
        help="Sobrescribe el checkpoint baseline del fixture para un diagnóstico explícito.",
    )
    parser.add_argument(
        "--moire-phase-isolation",
        action="store_true",
        help="Publica Cover Glow y Lens Projection con intensidad de moiré 0 y 1.",
    )
    parser.add_argument(
        "--moire-zero-downstream-isolation",
        action="store_true",
        help="Publica cada checkpoint desde Lens Projection con intensidad de moiré 0.",
    )
    parser.add_argument(
        "--glow-isolation",
        action="store_true",
        help="Publica Camera Rendered con Cover Glow 0, 1 y 4 sobre el mismo frame.",
    )
    arguments = parser.parse_args()
    if arguments.ideal_full_rgb and (
        arguments.moire_phase_isolation
        or arguments.moire_zero_downstream_isolation
    ):
        parser.error(
            "--ideal-full-rgb es un control final derivado de Lens Projection y no se combina con diagnósticos de checkpoints."
        )

    repository = Path(__file__).resolve().parent.parent
    fixture = arguments.fixture.expanduser()
    if not fixture.is_absolute():
        fixture = repository / fixture
    fixture = fixture.resolve()
    if not fixture.is_file():
        parser.error(f"No existe el fixture: {fixture}")

    output = arguments.output_dir.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"La salida debe ser nueva o estar vacía: {output}")
    output.mkdir(parents=True, exist_ok=True)

    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("SCREEN_MOIRE_") and not key.startswith("SCREEN_DIAGNOSTIC_")
    }
    environment.update(
        {
            "SCREEN_MOIRE_FIXTURE_PATH": str(fixture),
            "SCREEN_MOIRE_RESOURCE_ROOT": str(arguments.resource_root),
            "SCREEN_MOIRE_DIAGNOSTIC_DIR": str(output),
        }
    )
    if arguments.settings_document is not None:
        settings_document = arguments.settings_document.expanduser().resolve()
        if not settings_document.is_file():
            parser.error(f"No existe el documento de ajustes: {settings_document}")
        environment["SCREEN_MOIRE_SETTINGS_DOCUMENT_PATH"] = str(settings_document)
    if arguments.lens_evaluation_model is not None:
        environment["SCREEN_MOIRE_FORCE_LENS_EVALUATION_MODEL"] = (
            arguments.lens_evaluation_model
        )
    if arguments.moire_intensity is not None:
        environment["SCREEN_MOIRE_FORCE_INTENSITY"] = str(arguments.moire_intensity)
    if arguments.ideal_full_rgb:
        environment["SCREEN_MOIRE_DIAGNOSTIC_IDEAL_FULL_RGB"] = "1"
    if arguments.baseline_intermediate is not None:
        environment["SCREEN_MOIRE_FORCE_BASELINE_INTERMEDIATE"] = (
            arguments.baseline_intermediate
        )
    if arguments.moire_phase_isolation:
        environment["SCREEN_MOIRE_PHASE_ISOLATION"] = "1"
    if arguments.moire_zero_downstream_isolation:
        environment["SCREEN_MOIRE_ZERO_DOWNSTREAM_ISOLATION"] = "1"
    if arguments.glow_isolation:
        environment["SCREEN_GLOW_ISOLATION"] = "1"
    subprocess.run(
        ["cargo", "build", "-p", "screen-native-bridge", "--release"],
        cwd=repository,
        env=environment,
        check=True,
    )
    native = repository / "apps" / "screen-native-macos"
    subprocess.run(["swift", "package", "clean"], cwd=native, env=environment, check=True)
    subprocess.run(
        [
            "swift",
            "test",
            "--filter",
            "ScreenSimulationNativeTests.optionalMoireHeadlessDiagnosticIsDeterministic()",
        ],
        cwd=native,
        env=environment,
        check=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
