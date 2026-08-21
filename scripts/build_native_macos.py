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
APP_ICON = ROOT / "apps/screen-native-macos/Assets/AppIcon.icns"
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
EXPECTED_BRIDGE_HASH = "471bc5e68c0c8e08ba49741eea994fa7cc560b1ad1002211747153f9121a1c9c"


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


def macho_dependencies(path: Path) -> list[str]:
    output = subprocess.run(
        ["otool", "-L", str(path)], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ).stdout.splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in output if line.strip()]


def bundle_ffmpeg_libraries(executable: Path, frameworks: Path) -> None:
    """Bundle the complete Homebrew FFmpeg dylib closure under one app-local rpath."""
    frameworks.mkdir(parents=True, exist_ok=True)
    pending = [executable]
    copied: dict[str, Path] = {}
    while pending:
        subject = pending.pop()
        for dependency in macho_dependencies(subject):
            if not dependency.startswith("/opt/homebrew/"):
                continue
            source = Path(dependency).resolve()
            if not source.is_file():
                raise RuntimeError(f"required FFmpeg dependency is missing: {dependency}")
            destination = frameworks / Path(dependency).name
            if dependency not in copied:
                if not destination.exists():
                    shutil.copy2(source, destination)
                copied[dependency] = destination
                copied[str(source)] = destination
                if destination not in pending:
                    pending.append(destination)
    if not copied:
        raise RuntimeError("native executable did not link the required FFmpeg libraries")
    bundle_targets = [executable, *sorted(set(copied.values()))]
    for target in bundle_targets:
        for dependency in macho_dependencies(target):
            if dependency.startswith("/opt/homebrew/"):
                destination = copied.get(dependency) or copied.get(str(Path(dependency).resolve()))
                if destination is None:
                    raise RuntimeError(f"unbundled FFmpeg dependency: {dependency}")
                run(["install_name_tool", "-change", dependency, f"@rpath/{destination.name}", str(target)])
        if target != executable:
            run(["install_name_tool", "-id", f"@rpath/{target.name}", str(target)])
    run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)])


def main() -> int:
    verify_hash(CONFIG, EXPECTED_CONFIG_HASH)
    verify_hash(BRIDGE, EXPECTED_BRIDGE_HASH)
    run(["cargo", "build", "--release", "-p", "screen-native-bridge"])
    run(["swift", "build", "-c", "release"], PACKAGE)
    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    macos = BUNDLE / "Contents" / "MacOS"
    resources = BUNDLE / "Contents" / "Resources"
    frameworks = BUNDLE / "Contents" / "Frameworks"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(EXECUTABLE, macos / "ScreenSimulationNative")
    shutil.copytree(RESOURCE_BUNDLE, resources / RESOURCE_BUNDLE.name)
    shutil.copy2(APP_ICON, resources / "AppIcon.icns")
    bundle_ffmpeg_libraries(macos / "ScreenSimulationNative", frameworks)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "SCREEN-SIMULATION",
        "CFBundleExecutable": "ScreenSimulationNative",
        "CFBundleIconFile": "AppIcon.icns",
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
