#!/usr/bin/env python3
"""Verify the shipped FFmpeg media adapter is self-contained in the macOS bundle."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ("libavcodec", "libavformat", "libavutil", "libswscale")


def capture(arguments: list[str]) -> str:
    return subprocess.run(
        arguments,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout


def require(label: str, content: str) -> None:
    missing = [token for token in REQUIRED if token not in content]
    if missing:
        raise RuntimeError(f"native macOS {label} is missing FFmpeg libraries: {missing}")


def validate_dependency_graph() -> None:
    graph = capture(
        [
            "cargo",
            "tree",
            "-p",
            "screen-native-bridge",
            "--edges",
            "normal",
            "--prefix",
            "none",
        ]
    )
    if "ffmpeg-next" not in graph:
        raise RuntimeError("Rust bridge dependency graph does not include the FFmpeg adapter")


def validate_macho(binary: Path) -> None:
    if not binary.is_file():
        raise RuntimeError(f"native macOS binary does not exist: {binary}")
    dylibs = capture(["otool", "-L", str(binary)])
    require(f"linked dylibs for {binary.name}", dylibs)
    if "/opt/homebrew/" in dylibs:
        raise RuntimeError("native executable retains a Homebrew FFmpeg install name")
    rpaths = capture(["otool", "-l", str(binary)])
    if "@executable_path/../Frameworks" not in rpaths:
        raise RuntimeError("native executable has no app-local Frameworks rpath")


def validate_bundle(bundle: Path) -> None:
    if not bundle.is_dir():
        raise RuntimeError(f"native macOS bundle does not exist: {bundle}")
    frameworks = bundle / "Contents" / "Frameworks"
    if not frameworks.is_dir():
        raise RuntimeError("bundle has no Frameworks directory for FFmpeg")
    names = {path.name for path in frameworks.iterdir() if path.is_file()}
    missing = [token for token in REQUIRED if not any(name.startswith(token) for name in names)]
    if missing:
        raise RuntimeError(f"bundle is missing FFmpeg dylibs: {missing}")


def main() -> int:
    validate_dependency_graph()
    if len(sys.argv) == 1:
        print("native macOS FFmpeg dependency graph gate passed")
        return 0
    if len(sys.argv) != 3:
        raise RuntimeError("usage: check_native_macos_no_ffmpeg.py [EXECUTABLE BUNDLE]")
    executable = Path(sys.argv[1]).resolve()
    bundle = Path(sys.argv[2]).resolve()
    validate_macho(executable)
    validate_bundle(bundle)
    print("native macOS FFmpeg graph, Mach-O, rpath and bundle gate passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"native macOS FFmpeg gate failed: {error}", file=sys.stderr)
        raise SystemExit(1)
