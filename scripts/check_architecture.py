#!/usr/bin/env python3
"""Validate current package edges, path ownership, and archive isolation."""

from __future__ import annotations

import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ACTIVE_TEXT_SUFFIXES = {
    ".h", ".json", ".md", ".py", ".rs", ".slint", ".swift", ".toml", ".yml", ".yaml"
}


class ValidationError(RuntimeError):
    """One or more executable architecture contracts failed."""


def load_json(relative_path: str) -> dict[str, Any]:
    path = ROOT / relative_path
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"Cannot load {relative_path}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{relative_path} must contain one JSON object")
    return value


def run(command: list[str]) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise ValidationError(f"Required command is unavailable: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip()
        raise ValidationError(f"Command failed ({' '.join(command)}): {detail}") from error
    return result.stdout


def validate_domains() -> None:
    manifest = load_json("architecture/domains.json")
    if set(manifest) != {"schema", "version", "packages"}:
        raise ValidationError("domains.json has undeclared root fields")
    if manifest["schema"] != "screen_simulation_domains" or manifest["version"] != 1:
        raise ValidationError("domains.json has an unknown contract")
    declared_packages = manifest["packages"]
    if not isinstance(declared_packages, list) or not declared_packages:
        raise ValidationError("domains.json must declare packages")

    metadata = json.loads(run(["cargo", "metadata", "--format-version", "1", "--no-deps"]))
    workspace_ids = set(metadata["workspace_members"])
    actual = {
        package["name"]: package
        for package in metadata["packages"]
        if package["id"] in workspace_ids
    }
    declared_names = [entry["name"] for entry in declared_packages]
    if len(declared_names) != len(set(declared_names)):
        raise ValidationError("domains.json contains duplicate package names")
    if set(declared_names) != set(actual):
        missing = sorted(set(actual) - set(declared_names))
        extra = sorted(set(declared_names) - set(actual))
        raise ValidationError(f"Workspace/domain package mismatch; undeclared={missing}, absent={extra}")

    for entry in declared_packages:
        if set(entry) != {"name", "path", "owner", "allowed_local_dependencies"}:
            raise ValidationError(f"Package {entry.get('name')} has undeclared fields")
        name = entry["name"]
        package = actual[name]
        actual_path = Path(package["manifest_path"]).resolve().parent.relative_to(ROOT).as_posix()
        if actual_path != entry["path"]:
            raise ValidationError(f"Package {name} path is {actual_path}, expected {entry['path']}")
        local_dependencies = sorted(
            dependency["name"]
            for dependency in package["dependencies"]
            if dependency["name"] in actual
        )
        allowed = sorted(entry["allowed_local_dependencies"])
        if local_dependencies != allowed:
            raise ValidationError(
                f"Package {name} local dependencies are {local_dependencies}, expected {allowed}"
            )


def validate_swift_domains() -> None:
    manifest = load_json("architecture/swift-domains.json")
    if set(manifest) != {"schema", "version", "packages"}:
        raise ValidationError("swift-domains.json has undeclared root fields")
    if (
        manifest["schema"] != "screen_simulation_swift_domains"
        or manifest["version"] != 1
    ):
        raise ValidationError("swift-domains.json has an unknown contract")

    for package_entry in manifest["packages"]:
        if set(package_entry) != {"path", "targets"}:
            raise ValidationError("A Swift package has undeclared fields")
        package_path = package_entry["path"]
        description = json.loads(
            run([
                "swift", "package", "--package-path", package_path,
                "describe", "--type", "json",
            ])
        )
        actual = {target["name"]: target for target in description["targets"]}
        declared = {target["name"]: target for target in package_entry["targets"]}
        if set(actual) != set(declared):
            missing = sorted(set(actual) - set(declared))
            extra = sorted(set(declared) - set(actual))
            raise ValidationError(
                f"Swift target mismatch in {package_path}; undeclared={missing}, absent={extra}"
            )
        for name, declaration in declared.items():
            if set(declaration) != {
                "name", "owner", "allowed_target_dependencies",
                "allowed_product_dependencies",
            }:
                raise ValidationError(f"Swift target {name} has undeclared fields")
            target = actual[name]
            target_dependencies = sorted(target.get("target_dependencies", []))
            product_dependencies = sorted(target.get("product_dependencies", []))
            allowed_targets = sorted(declaration["allowed_target_dependencies"])
            allowed_products = sorted(declaration["allowed_product_dependencies"])
            if target_dependencies != allowed_targets:
                raise ValidationError(
                    f"Swift target {name} dependencies are {target_dependencies}, "
                    f"expected {allowed_targets}"
                )
            if product_dependencies != allowed_products:
                raise ValidationError(
                    f"Swift target {name} products are {product_dependencies}, "
                    f"expected {allowed_products}"
                )


def repository_paths() -> list[str]:
    output = run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    return sorted(
        path for path in output.split("\0")
        if path and (ROOT / path).exists()
    )


def validate_path_owners(paths: list[str]) -> None:
    manifest = load_json("architecture/validation-owners.json")
    if set(manifest) != {"schema", "version", "owners"}:
        raise ValidationError("validation-owners.json has undeclared root fields")
    if (
        manifest["schema"] != "screen_simulation_validation_owners"
        or manifest["version"] != 1
    ):
        raise ValidationError("validation-owners.json has an unknown contract")

    owners = manifest["owners"]
    owner_ids = [owner["id"] for owner in owners]
    if len(owner_ids) != len(set(owner_ids)):
        raise ValidationError("validation-owners.json contains duplicate owner ids")
    for owner in owners:
        if set(owner) != {"id", "paths", "checks"}:
            raise ValidationError(f"Validation owner {owner.get('id')} has undeclared fields")
        if not owner["paths"] or not owner["checks"]:
            raise ValidationError(f"Validation owner {owner['id']} must declare paths and checks")

    failures: list[str] = []
    for path in paths:
        matches = [
            owner["id"]
            for owner in owners
            if any(fnmatch.fnmatchcase(path, pattern) for pattern in owner["paths"])
        ]
        if len(matches) != 1:
            failures.append(f"{path}: expected one validation owner, found {matches}")
    if failures:
        raise ValidationError("Invalid validation ownership:\n" + "\n".join(failures))


def validate_archive_isolation(paths: list[str]) -> None:
    markdown_link = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
    for relative_path in paths:
        if relative_path.startswith("Docs/old/"):
            continue
        path = ROOT / relative_path
        if path.suffix.lower() != ".md":
            continue
        text = path.read_text(encoding="utf-8")
        for target in markdown_link.findall(text):
            normalized = target.replace("\\", "/").lower()
            if normalized.startswith("docs/old/") or "/old/" in normalized or normalized.startswith("../old/"):
                raise ValidationError(f"Active document {relative_path} links to the sealed archive")


def validate_retired_surfaces(paths: list[str]) -> None:
    manifest = load_json("architecture/retired.json")
    if set(manifest) != {"schema", "version", "paths", "identifiers"}:
        raise ValidationError("retired.json has undeclared root fields")
    if manifest["schema"] != "screen_simulation_retired_surfaces" or manifest["version"] != 1:
        raise ValidationError("retired.json has an unknown contract")

    for retired_path in manifest["paths"]:
        matches = [path for path in paths if fnmatch.fnmatchcase(path, retired_path)]
        if matches:
            raise ValidationError(f"Retired path returned ({retired_path}): {matches}")

    identifiers = manifest["identifiers"]
    if not identifiers:
        return
    for relative_path in paths:
        if relative_path == "architecture/retired.json" or relative_path.startswith("Docs/old/"):
            continue
        path = ROOT / relative_path
        if path.suffix.lower() not in ACTIVE_TEXT_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8")
        for identifier in identifiers:
            if identifier in text:
                raise ValidationError(f"Retired identifier {identifier!r} returned in {relative_path}")


def validate_native_backend_composition(paths: list[str]) -> None:
    required_paths = {
        "crates/screen-platform/shaders/native_camera.metal",
        "crates/screen-platform/shaders/spatial_optics.metal",
        "Docs/architecture/native_compute.md",
    }
    missing = sorted(required_paths - set(paths))
    if missing:
        raise ValidationError(f"Native Metal boundary is incomplete; missing={missing}")
    desktop = (ROOT / "apps/screen-desktop/src/main.rs").read_text(encoding="utf-8")
    required_calls = [
        "MetalRawDevelopment::new()",
        "capture_and_develop_procedural_region_with_compute_backends(",
        "capture_and_develop_device_signal_region_with_compute_backends(",
        "capture_and_develop_device_signal_region_sequence_with_compute_backends(",
    ]
    absent = [call for call in required_calls if call not in desktop]
    if absent:
        raise ValidationError(f"Desktop Native composition does not require Metal; absent={absent}")
    cpu_calls = [
        "capture_and_develop_procedural_region(",
        "capture_and_develop_device_signal_region(",
        "capture_and_develop_device_signal_region_sequence(",
    ]
    present = [call for call in cpu_calls if call in desktop]
    if present:
        raise ValidationError(f"Desktop Native composition calls CPU reference entrypoints: {present}")


def validate_presentation_boundaries() -> None:
    mac_ui_root = ROOT / "apps/screen-native-macos/Sources/ScreenSimulationMacUI"
    forbidden_ui_identifiers = [
        "DeviceDefinition",
        "PhysicalIntermediate",
        "ScreenPhysicalBridge",
        "StudioColor",
        "StudioMedia",
        "acescg",
        "colorModeIDs",
        "device-signal",
        "feeder-signal",
        "outputSignalID",
        "placementID",
        "previewQualityID",
        "rec709",
        "srgb",
        "whiteLevelNits",
    ]
    for path in mac_ui_root.glob("**/*.swift"):
        text = path.read_text(encoding="utf-8")
        present = [identifier for identifier in forbidden_ui_identifiers if identifier in text]
        if present:
            relative = path.relative_to(ROOT).as_posix()
            raise ValidationError(
                f"Presentation target {relative} contains model semantics: {present}"
            )

    content = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/ContentView.swift"
    ).read_text(encoding="utf-8")
    start = content.find("private var testWorkspace")
    end = content.find("private var monitorSettings", start)
    if start < 0 or end < 0:
        raise ValidationError("ContentView must contain one bounded Test workspace shell")
    test_shell = content[start:end]
    forbidden_shell_identifiers = [
        "ForEach(Physical",
        "Input Transform",
        "PhysicalIntermediate",
        "StudioColorMode",
        "TestPhaseOption",
        "TextField(",
        "colorModeID",
        "whiteLevelNits",
    ]
    present = [identifier for identifier in forbidden_shell_identifiers if identifier in test_shell]
    if present:
        raise ValidationError(f"Test workspace hard-codes model controls: {present}")


def validate_native_model_authority() -> None:
    application = (
        ROOT / "crates/screen-application/src/physical_pipeline.rs"
    ).read_text(encoding="utf-8")
    for required in (
        "pub const PHYSICAL_STAGE_DESCRIPTORS",
        "pub struct PhysicalStageDescriptor",
        "pub enum PhysicalStageControlSemantics",
    ):
        if required not in application:
            raise ValidationError(
                f"Application does not publish the physical-stage authority: {required}"
            )

    bridge = (ROOT / "crates/screen-native-bridge/src/lib.rs").read_text(encoding="utf-8")
    forbidden_bridge = (
        "EXPECTED_STAGE_IDS",
        "ScreenPhysicalStageContributionV2",
        "contribution.visual_minimum",
        "contribution.visual_maximum",
        "contribution.safe_maximum",
    )
    present = [value for value in forbidden_bridge if value in bridge]
    if present:
        raise ValidationError(f"Native bridge duplicates physical-stage semantics: {present}")

    contract = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/PhysicalFrameContract.swift"
    ).read_text(encoding="utf-8")
    required_contract = (
        "screen_physical_stage_descriptor_count()",
        "screen_physical_stage_descriptor(index, &raw)",
        "PhysicalStageCatalog.descriptors.map(\\.stage)",
    )
    absent = [value for value in required_contract if value not in contract]
    if absent:
        raise ValidationError(f"Native host does not consume Application stage descriptors: {absent}")
    if "static let ordered: [Self]" in contract:
        raise ValidationError("Native host declares a second physical-stage order")

    workspace = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/WorkspaceModel.swift"
    ).read_text(encoding="utf-8")
    if "private func physicalIntermediate(" in workspace:
        raise ValidationError("Native host reconstructs phase-to-intermediate routing")

    frame_check = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/FrameCheckPNG.swift"
    ).read_text(encoding="utf-8")
    forbidden_png_compatibility = (
        "PhysicalFrame.v1",
        "metadataForSelectedImport",
    )
    present = [value for value in forbidden_png_compatibility if value in frame_check]
    if present:
        raise ValidationError(
            f"Normal PNG import exposes retired compatibility readers: {present}"
        )


def validate_phase_gated_workflow() -> None:
    rules = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    required = [
        "## Phase-gated implementation",
        "present a non-technical high-level summary",
        "wait for explicit user confirmation",
        "comparable old/new diagnostic PNGs",
        "canonical checkpoint feeding the next phase",
    ]
    absent = [statement for statement in required if statement not in rules]
    if absent:
        raise ValidationError(f"Phase-gated workflow rule is incomplete: {absent}")


def main() -> int:
    try:
        paths = repository_paths()
        validate_domains()
        validate_swift_domains()
        validate_path_owners(paths)
        validate_archive_isolation(paths)
        validate_retired_surfaces(paths)
        validate_native_backend_composition(paths)
        validate_presentation_boundaries()
        validate_native_model_authority()
        validate_phase_gated_workflow()
    except (ValidationError, json.JSONDecodeError) as error:
        print(f"architecture validation failed: {error}", file=sys.stderr)
        return 1
    print("architecture validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
