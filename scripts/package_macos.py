#!/usr/bin/env python3
"""Build the current macOS test application bundle from the release binary."""

from __future__ import annotations

import plistlib
import shutil
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASE_BINARY = ROOT / "target" / "release" / "screen-desktop"
BUNDLE = ROOT / "dist" / "Screen Simulation.app"
CONTENTS = BUNDLE / "Contents"
MACOS = CONTENTS / "MacOS"
BUNDLED_BINARY = MACOS / "screen-desktop"


def run(command: list[str]) -> None:
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    run(["cargo", "build", "--release", "-p", "screen-desktop"])

    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    MACOS.mkdir(parents=True)
    shutil.copy2(RELEASE_BINARY, BUNDLED_BINARY)
    BUNDLED_BINARY.chmod(BUNDLED_BINARY.stat().st_mode | stat.S_IXUSR)

    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Screen Simulation",
        "CFBundleExecutable": "screen-desktop",
        "CFBundleIdentifier": "com.jtorrens.screensimulation",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Screen Simulation",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with (CONTENTS / "Info.plist").open("wb") as plist_file:
        plistlib.dump(info, plist_file, sort_keys=True)

    run(["codesign", "--force", "--sign", "-", str(BUNDLE)])
    run(["codesign", "--verify", "--deep", "--strict", str(BUNDLE)])
    print(BUNDLE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
