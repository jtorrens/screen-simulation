#!/usr/bin/env python3
"""Build the current macOS test application bundle from the release binary."""

from __future__ import annotations

import plistlib
import os
import shutil
import stat
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASE_BINARY = ROOT / "target" / "release" / "screen-desktop"
BUNDLE = ROOT / "dist" / "Screen Simulation.app"
CONTENTS = BUNDLE / "Contents"
MACOS = CONTENTS / "MacOS"
FRAMEWORKS = CONTENTS / "Frameworks"
RESOURCES = CONTENTS / "Resources"
BUNDLED_BINARY = MACOS / "screen-desktop"
METAL_SOURCES = [
    ROOT / "crates" / "screen-platform" / "shaders" / "native_camera.metal",
    ROOT / "crates" / "screen-platform" / "shaders" / "spatial_optics.metal",
]
METAL_LIBRARY = RESOURCES / "native_camera.metallib"
LOADER_RPATH = "@executable_path/../Frameworks"


def run(command: list[str], *, environment: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=ROOT, check=True, env=environment)


def capture(command: list[str]) -> str:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout


def dependencies(binary: Path) -> list[str]:
    lines = capture(["otool", "-L", str(binary)]).splitlines()[1:]
    return [line.strip().split(" (compatibility version", 1)[0] for line in lines]


def rpaths(binary: Path) -> list[str]:
    lines = capture(["otool", "-l", str(binary)]).splitlines()
    result: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH" and index + 2 < len(lines):
            path_line = lines[index + 2].strip()
            if path_line.startswith("path "):
                result.append(path_line[5:].split(" (offset", 1)[0])
    return result


def is_system_dependency(path: str) -> bool:
    return path.startswith("/System/Library/") or path.startswith("/usr/lib/")


def resolve_dependency(path: str, loader: Path) -> Path:
    if path.startswith("/"):
        resolved = Path(path)
    elif path.startswith("@loader_path/"):
        resolved = loader.parent / path.removeprefix("@loader_path/")
    elif path.startswith("@rpath/"):
        suffix = path.removeprefix("@rpath/")
        candidates = []
        for entry in rpaths(loader):
            if entry.startswith("@loader_path/"):
                candidates.append(loader.parent / entry.removeprefix("@loader_path/") / suffix)
            elif entry.startswith("/"):
                candidates.append(Path(entry) / suffix)
        candidates.append(FRAMEWORKS / suffix)
        resolved = next((candidate for candidate in candidates if candidate.exists()), Path())
    else:
        raise RuntimeError(f"unsupported Mach-O dependency route {path!r} in {loader}")
    if not resolved.is_file():
        raise RuntimeError(f"cannot resolve Mach-O dependency {path!r} in {loader}")
    return resolved.resolve()


def remove_machine_rpaths(binary: Path) -> None:
    for entry in rpaths(binary):
        if entry == LOADER_RPATH or entry.startswith("/System/Library/") or entry.startswith(
            "/usr/lib/"
        ):
            continue
        run(["install_name_tool", "-delete_rpath", entry, str(binary)])


def bundle_non_system_dependencies() -> list[Path]:
    FRAMEWORKS.mkdir(parents=True)
    run(["install_name_tool", "-add_rpath", LOADER_RPATH, str(BUNDLED_BINARY)])
    queued = [BUNDLED_BINARY]
    processed: set[Path] = set()
    source_by_name: dict[str, Path] = {}
    bundled: list[Path] = []

    while queued:
        binary = queued.pop(0)
        if binary in processed:
            continue
        processed.add(binary)
        binary_dependencies = dependencies(binary)
        for dependency in binary_dependencies:
            if is_system_dependency(dependency):
                continue
            source = resolve_dependency(dependency, binary)
            destination = FRAMEWORKS / source.name
            prior_source = source_by_name.get(source.name)
            if (
                prior_source is not None
                and prior_source != source
                and prior_source != destination.resolve()
                and source != destination.resolve()
            ):
                raise RuntimeError(
                    f"Mach-O dependency basename collision: {prior_source} and {source}"
                )
            source_by_name[source.name] = source
            if not destination.exists():
                shutil.copy2(source, destination)
                destination.chmod(destination.stat().st_mode | stat.S_IWUSR)
                run(["install_name_tool", "-id", f"@rpath/{destination.name}", str(destination)])
                bundled.append(destination)
            run(
                [
                    "install_name_tool",
                    "-change",
                    dependency,
                    f"@rpath/{destination.name}",
                    str(binary),
                ]
            )
            queued.append(destination)
        remove_machine_rpaths(binary)

    return bundled


def verify_portable_dependencies(binaries: list[Path]) -> None:
    for binary in binaries:
        for dependency in dependencies(binary):
            if is_system_dependency(dependency):
                continue
            if dependency.startswith("@rpath/"):
                bundled = FRAMEWORKS / dependency.removeprefix("@rpath/")
                if bundled.is_file():
                    continue
            raise RuntimeError(f"non-portable dependency {dependency!r} remains in {binary}")
        for entry in rpaths(binary):
            if entry == LOADER_RPATH or entry.startswith("/System/Library/") or entry.startswith(
                "/usr/lib/"
            ):
                continue
            raise RuntimeError(f"machine-specific rpath {entry!r} remains in {binary}")


def bundle_native_shaders() -> None:
    RESOURCES.mkdir(parents=True)
    air_files = []
    for source in METAL_SOURCES:
        air = RESOURCES / f"{source.stem}.air"
        compile_arguments = ["xcrun", "-sdk", "macosx", "metal", "-c"]
        if source.name == "spatial_optics.metal":
            compile_arguments.extend(["-fmetal-math-mode=safe", "-ffp-contract=off"])
        run([*compile_arguments, str(source), "-o", str(air)])
        air_files.append(air)
    run(
        [
            "xcrun",
            "-sdk",
            "macosx",
            "metallib",
            *[str(air) for air in air_files],
            "-o",
            str(METAL_LIBRARY),
        ]
    )
    for air in air_files:
        air.unlink()
    if not METAL_LIBRARY.is_file() or METAL_LIBRARY.stat().st_size == 0:
        raise RuntimeError("packaged Native Metal shader library is missing or empty")


def main() -> int:
    build_environment = os.environ.copy()
    build_environment["SCREEN_SIM_BUILD_ID"] = capture(
        ["git", "rev-parse", "--short=8", "HEAD"]
    ).strip()
    run(
        ["cargo", "build", "--release", "-p", "screen-desktop"],
        environment=build_environment,
    )

    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    MACOS.mkdir(parents=True)
    shutil.copy2(RELEASE_BINARY, BUNDLED_BINARY)
    BUNDLED_BINARY.chmod(BUNDLED_BINARY.stat().st_mode | stat.S_IXUSR)
    bundle_native_shaders()

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

    bundled_libraries = bundle_non_system_dependencies()
    verify_portable_dependencies([BUNDLED_BINARY, *bundled_libraries])
    for library in bundled_libraries:
        run(["codesign", "--force", "--sign", "-", str(library)])
    run(["codesign", "--force", "--sign", "-", str(BUNDLE)])
    run(["codesign", "--verify", "--deep", "--strict", str(BUNDLE)])
    print(BUNDLE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
