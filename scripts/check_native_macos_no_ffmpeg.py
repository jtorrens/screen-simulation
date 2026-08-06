#!/usr/bin/env python3
"""Reject FFmpeg from the native macOS dependency graph and product."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BANNED = (
    "ffmpeg",
    "avcodec",
    "avformat",
    "avutil",
    "swscale",
    "swresample",
)


def capture(arguments: list[str]) -> str:
    return subprocess.run(
        arguments,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout


def reject(label: str, content: str) -> None:
    lowered = content.lower()
    matches = sorted(token for token in BANNED if token in lowered)
    if matches:
        raise RuntimeError(f"native macOS {label} contains forbidden FFmpeg tokens: {matches}")


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
    reject("Rust bridge dependency graph", graph)


def validate_macho(binary: Path) -> None:
    if not binary.is_file():
        raise RuntimeError(f"native macOS binary does not exist: {binary}")
    reject(f"linked dylibs for {binary.name}", capture(["otool", "-L", str(binary)]))
    reject(f"load commands/rpaths for {binary.name}", capture(["otool", "-l", str(binary)]))
    reject(f"symbols for {binary.name}", capture(["nm", "-a", str(binary)]))
    reject(f"embedded strings for {binary.name}", capture(["strings", str(binary)]))


def validate_bundle(bundle: Path) -> None:
    if not bundle.is_dir():
        raise RuntimeError(f"native macOS bundle does not exist: {bundle}")
    for path in bundle.rglob("*"):
        reject("bundle resource path", path.relative_to(bundle).as_posix())


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
    print("native macOS FFmpeg graph, Mach-O, symbol, rpath and bundle gate passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"native macOS FFmpeg gate failed: {error}", file=sys.stderr)
        raise SystemExit(1)
