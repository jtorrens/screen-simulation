#!/usr/bin/env python3
"""Build and package the current SwiftUI/AppKit macOS application."""

from __future__ import annotations

import hashlib
import os
import plistlib
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "apps" / "screen-native-macos"
BUILD = PACKAGE / ".build" / "arm64-apple-macosx" / "release"
BUNDLE = ROOT / "dist" / "Screen Simulation Native.app"
EXECUTABLE = BUILD / "ScreenSimulationNative"
RESOURCE_BUNDLE = BUILD / "StudioColor_StudioColor.bundle"
CONFIG = (
    ROOT
    / "packages/StudioColor/Sources/StudioColor/Resources"
    / "studio-config-v4.0.0_aces-v2.0_ocio-v2.5.ocio"
)
BRIDGE = (
    ROOT
    / "packages/StudioColor/Vendor/StudioColorNativeBridge.xcframework"
    / "macos-arm64_x86_64/libCreditsNativeBridge.a"
)
EXPECTED_CONFIG_HASH = "ebe2293968975e3540c6b32cfbee2ca1274b5bf3c9ff610235abb07b65da970b"
EXPECTED_BRIDGE_HASH = "680eef3911af83b3579d7b7dbe27c9970d273859edd3b5fbdc0a2cc8968ee67f"


def run(arguments: list[str], cwd: Path = ROOT) -> None:
    environment = os.environ.copy()
    cache = ROOT / "target" / "swift-cache"
    cache.mkdir(parents=True, exist_ok=True)
    environment["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(cache / "swiftpm")
    environment["XDG_CACHE_HOME"] = str(cache / "xdg")
    environment["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    subprocess.run(arguments, cwd=cwd, check=True, env=environment)


def verify_hash(path: Path, expected: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise RuntimeError(f"hash mismatch for {path}: {actual}")


def main() -> int:
    verify_hash(CONFIG, EXPECTED_CONFIG_HASH)
    verify_hash(BRIDGE, EXPECTED_BRIDGE_HASH)
    run(["cargo", "build", "--release", "-p", "screen-native-bridge"])
    run(["swift", "build", "-c", "release"], PACKAGE)
    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    macos = BUNDLE / "Contents" / "MacOS"
    resources = BUNDLE / "Contents" / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(EXECUTABLE, macos / "ScreenSimulationNative")
    shutil.copytree(RESOURCE_BUNDLE, resources / RESOURCE_BUNDLE.name)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "SCREEN-SIMULATION",
        "CFBundleExecutable": "ScreenSimulationNative",
        "CFBundleIdentifier": "com.jtorrens.screensimulation.native",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "SCREEN-SIMULATION",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with (BUNDLE / "Contents" / "Info.plist").open("wb") as output:
        plistlib.dump(info, output)
    run(
        [
            "python3",
            "scripts/check_native_macos_no_ffmpeg.py",
            str(macos / "ScreenSimulationNative"),
            str(BUNDLE),
        ]
    )
    run(
        [
            "python3",
            "scripts/check_native_physical_abi.py",
            str(macos / "ScreenSimulationNative"),
        ]
    )
    run(["codesign", "--force", "--deep", "--sign", "-", str(BUNDLE)])
    run(["codesign", "--verify", "--deep", "--strict", str(BUNDLE)])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
