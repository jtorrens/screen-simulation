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
    arguments = parser.parse_args()

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
