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

from check_decision_authority import DecisionAuthorityError, validate as validate_decision_authority


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

    test_authoring = (
        ROOT / "crates/screen-application/src/test_authoring.rs"
    ).read_text(encoding="utf-8")
    for required in (
        "pub enum PhysicalArtifactId",
        "pub const fn stable_id(self) -> &'static str",
        "pub input_artifact: PhysicalArtifactId",
        "pub output_artifact: PhysicalArtifactId",
    ):
        if required not in test_authoring:
            raise ValidationError(
                f"Application does not publish typed physical artifacts: {required}"
            )
    for forbidden in (
        "pub input_artifact: &'static str",
        "pub output_artifact: &'static str",
    ):
        if forbidden in test_authoring:
            raise ValidationError(
                f"Application publishes an untyped physical artifact identity: {forbidden}"
            )

    application_pipeline = (ROOT / "crates/screen-application/src/lib.rs").read_text(
        encoding="utf-8"
    )
    for required in (
        "pub enum PhysicalPipelineCpuArtifact",
        "SensorCollection {",
        "SensorBloom {",
        "SensorReadoutRaw {",
        "raw: RawSensorRaster",
        "pub fn presentation_rgba(&self)",
        "pub artifact: PhysicalPipelineCpuArtifact",
        "pub struct PhysicalRenderContext",
        "pub window: PhysicalRenderWindow",
        "pub scale_x: ExactPositiveRatio",
        "pub scale_y: ExactPositiveRatio",
        "pub pixel_aspect: ExactPositiveRatio",
        "pub render_context: PhysicalRenderContext",
    ):
        if required not in application_pipeline:
            raise ValidationError(
                f"CPU physical publication is not a typed artifact: {required}"
            )

    physical_header = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenPhysicalBridge/include/ScreenPhysicalBridge.h"
    ).read_text(encoding="utf-8")
    for required in (
        "render_full_width",
        "render_full_height",
        "render_window_x",
        "render_window_y",
        "render_window_width",
        "render_window_height",
        "render_scale_x_numerator",
        "render_scale_x_denominator",
        "render_scale_y_numerator",
        "render_scale_y_denominator",
        "pixel_aspect_numerator",
        "pixel_aspect_denominator",
    ):
        if required not in physical_header:
            raise ValidationError(
                f"physical host ABI omits explicit render context field: {required}"
            )
    if "pub struct PhysicalPipelineCpuResult {\n    pub width:" in application_pipeline:
        raise ValidationError("CPU physical publication exposes an untyped raster result")
    if "pub struct PhysicalPipelineCpuResult {\n    pub acescg:" in application_pipeline:
        raise ValidationError("CPU physical publication relabels every artifact as ACEScg")

    physical_pipeline_contract = (
        ROOT / "crates/screen-application/src/physical_pipeline.rs"
    ).read_text(encoding="utf-8")
    for required in (
        "pub fn resolve_physical_stage_contributions(",
        "pub struct ResolvedPhysicalStageContributions",
    ):
        if required not in physical_pipeline_contract:
            raise ValidationError(
                f"Application does not own physical contribution resolution: {required}"
            )

    native_bridge_product = (
        ROOT / "crates/screen-native-bridge/src/lib.rs"
    ).read_text(encoding="utf-8").split("#[cfg(test)]", 1)[0]
    for forbidden in (
        "contributions[12]",
        "contributions[13]",
        "contributions[14]",
        "contributions[15]",
    ):
        if forbidden in native_bridge_product:
            raise ValidationError(
                f"native bridge reinterprets physical stage order by index: {forbidden}"
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
    forbidden_viewer_state = (
        "@Published var zoom",
        "@Published var pan",
        "@Published private(set) var previewIsFitted",
        "@Published var modelViewerOneToOne",
    )
    present = [value for value in forbidden_viewer_state if value in workspace]
    if present:
        raise ValidationError(
            f"WorkspaceModel reclaims Viewer-navigation state: {present}"
        )
    viewer_navigation = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/ViewerNavigationController.swift"
    ).read_text(encoding="utf-8")
    for required in ("final class ViewerNavigationController", "func fit()", "func restore("):
        if required not in viewer_navigation:
            raise ValidationError(f"Viewer-navigation owner omits contract: {required}")
    forbidden_output_queue_state = (
        "struct RenderJob: Identifiable",
        "@Published var jobs:",
        "private var renderTask:",
    )
    present = [value for value in forbidden_output_queue_state if value in workspace]
    if present:
        raise ValidationError(f"WorkspaceModel reclaims output-queue lifecycle: {present}")
    output_queue = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/NativeOutputQueueController.swift"
    ).read_text(encoding="utf-8")
    for required in (
        "final class NativeOutputQueueController",
        "struct RenderJob: Codable, Identifiable",
        "func enqueue(",
        "func cancel()",
    ):
        if required not in output_queue:
            raise ValidationError(f"Native output-queue owner omits contract: {required}")

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

    test_authoring = (
        ROOT / "crates/screen-application/src/test_authoring.rs"
    ).read_text(encoding="utf-8")
    if "pub frame_rate: f32" in test_authoring:
        raise ValidationError("Test authoring transports frame rate as floating point")

    native_header = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenPhysicalBridge/include/ScreenPhysicalBridge.h"
    ).read_text(encoding="utf-8")
    if "float frame_rate" in native_header:
        raise ValidationError("Native Test authoring ABI transports frame rate as float")
    for required in ("frame_rate_numerator", "frame_rate_denominator"):
        if required not in native_header:
            raise ValidationError(f"Native Test authoring ABI omits exact cadence: {required}")

    media_interpretation = (
        ROOT / "packages/StudioMedia/Sources/StudioMedia/InputInterpretation.swift"
    ).read_text(encoding="utf-8")
    if "case defaulted" in media_interpretation:
        raise ValidationError("Media metadata exposes a silent default provenance")
    forbidden_media_authoring = (
        "detection.proposedInputTransformID ??",
        "detection.alpha ??",
        "detection.matrix ??",
        "detection.range ??",
        "detection.colorModel ??",
        "referenceDetection.proposedInputTransformID ??",
        "referenceDetection.alpha ??",
        "referenceDetection.matrix ??",
        "referenceDetection.range ??",
        "referenceDetection.colorModel ??",
    )
    present = [value for value in forbidden_media_authoring if value in workspace]
    if present:
        raise ValidationError(
            f"Native media import silently authors metadata or defaults: {present}"
        )
    for required in (
        "StudioMediaImportResolution",
        'resolved.proposedInputTransformID = "srgb-encoded-rec709"',
        "resolved.alpha = resolved.hasAlpha ? .premultiplied : .ignore",
        "nonMetadataFields",
    ):
        if required not in media_interpretation:
            raise ValidationError(
                f"Media import omits the disclosed incomplete-metadata contract: {required}"
            )
    for required in (
        "adoptSourceImportInterpretation",
        "adoptReferenceImportInterpretation",
        "acknowledgeImportDefaults",
        "materializeImportInterpretation: false",
    ):
        if required not in workspace:
            raise ValidationError(
                f"Native Source/Reference import omits disclosed defaults or persisted-authoring isolation: {required}"
            )

    output_contracts = (
        ROOT / "packages/StudioMedia/Sources/StudioMedia/OutputContracts.swift"
    ).read_text(encoding="utf-8")
    if "public let frameRate: Double" in output_contracts:
        raise ValidationError("Resolved output jobs transport frame rate as floating point")
    for required in ("StudioFrameRate", "numerator", "denominator"):
        if required not in output_contracts and required not in media_interpretation:
            raise ValidationError(f"StudioMedia omits exact output cadence: {required}")


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


def validate_scene_self_containment() -> None:
    tracking_asset_library = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/TrackingAssetLibrary.swift"
    )
    if tracking_asset_library.exists():
        raise ValidationError("Imported 3D authoring still has a managed importer-file library")

    scene_library = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/SceneLibrary.swift"
    ).read_text(encoding="utf-8")
    match = re.search(
        r"struct SavedTrackingScene:.*?\n}\n\n/// Scene persistence",
        scene_library,
        flags=re.DOTALL,
    )
    if not match:
        raise ValidationError("SavedTrackingScene contract is missing")
    saved_tracking = match.group(0)
    if "let scene: TrackingScene" not in saved_tracking:
        raise ValidationError("Saved tracking does not embed complete scene-owned 3D authoring")
    forbidden = [value for value in ("absolutePath", ".comp", "URL", "fileName") if value in saved_tracking]
    if forbidden:
        raise ValidationError(f"Saved tracking retains importer-file identity: {forbidden}")

    workspace = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/WorkspaceModel.swift"
    ).read_text(encoding="utf-8")
    restore = re.search(
        r"private func restoreTrackingScene\(.*?\n    }\n\n    private func currentFrameCheckMetadata",
        workspace,
        flags=re.DOTALL,
    )
    if not restore or "trackingScene = saved.scene" not in restore.group(0):
        raise ValidationError("Scene Open does not restore embedded 3D authoring directly")
    if any(value in restore.group(0) for value in ("FusionTrackingImporter", "FileManager", ".comp")):
        raise ValidationError("Scene Open re-enters the 3D importer boundary")
    for forbidden in ("MEDIA MISSING", "publishMissingMedia", "missingMediaFrame"):
        if forbidden in workspace:
            raise ValidationError(
                "Saved Scene external media still exposes a retired placeholder route: "
                + forbidden
            )
    for required in (
        "var hasExternalSourceMedia: Bool",
        "func removeExternalSourceMedia()",
        "session.reset()",
        "choosePattern(selectedPattern, undoManager: nil)",
    ):
        if required not in workspace:
            raise ValidationError(
                "Source removal does not re-enter the canonical synthetic-source route: "
                + required
            )

    content_view = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/ContentView.swift"
    ).read_text(encoding="utf-8")
    for required in (
        "if model.hasExternalSourceMedia",
        'Button("Quitar", action: model.removeExternalSourceMedia)',
    ):
        if required not in content_view:
            raise ValidationError(
                "Source authoring UI omits explicit external-media removal: " + required
            )


def validate_fusion_scene_color_contract() -> None:
    fusion = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/FusionScenePackage.swift"
    ).read_text(encoding="utf-8")
    for forbidden in (
        "OCIOColorSpace",
        "OCIOConfig",
        "studio-fusion-ocio",
        "fusionConfigurationFileName",
        "ocioSourceColorSpace",
    ):
        if forbidden in fusion:
            raise ValidationError(
                f"Fusion Scene Package retains an OCIO composition route: {forbidden}"
            )
    for required in (
        "ReferenceToACEScg = ColorSpaceTransform",
        'InputGamma = Input { Value = FuID { \"REC709_GAMMA\" } }',
        'OutputColorSpace = Input { Value = FuID { \"ACES_AP1_COLORSPACE\" } }',
        "UseHDRStandardConversions = Input { Value = 1 }",
        "IsRec2390ScalingEnabled = Input { Value = 1 }",
        '"  PassThrough = true,\\n"',
    ):
        if required not in fusion:
            raise ValidationError(
                f"Fusion reference transform omits its standard-node contract: {required}"
            )
    fusion_config = (
        ROOT
        / "packages/StudioColor/Sources/StudioColor/Resources/studio-fusion-ocio-v2.4.ocio"
    )
    if fusion_config.exists():
        raise ValidationError("Fusion package still ships a private OCIO configuration")


def validate_scene_profile_authority() -> None:
    scene_library = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/SceneLibrary.swift"
    ).read_text(encoding="utf-8")
    match = re.search(
        r"struct SceneAuthoringDocument:.*?\n}\n\nstruct SavedSceneSnapshot",
        scene_library,
        flags=re.DOTALL,
    )
    if not match:
        raise ValidationError("SceneAuthoringDocument contract is missing")
    authoring = match.group(0)
    for required in (
        "let profiles: SceneProfileSelection",
        "let overrides: [SceneControlOverride]",
        "let modelOverrides: SceneModelOverrides",
    ):
        if required not in authoring:
            raise ValidationError(f"Saved Scene omits selected profile identity: {required}")
    for forbidden in (
        "let device: DeviceDefinition",
        "let coverGlass: CoverGlassDefinition",
        "TestAuthoringResolvedSelection",
        "PhysicalSettingsExchange.FrameContext",
        "let model: PhysicalModelAuthoringState",
    ):
        if forbidden in authoring:
            raise ValidationError(
                f"Saved Scene embeds a complete current profile snapshot: {forbidden}"
            )

    workspace = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/WorkspaceModel.swift"
    ).read_text(encoding="utf-8")
    for forbidden in (
        "RustDeviceCatalog.builtIns",
        "RustCoverGlassCatalog.builtIns",
        "CapturePresetDefinition.catalog",
        "LensPresetDefinition.catalog",
        "EnvironmentPresetDefinition.catalog",
        "StudioRenderPreset.builtIns",
    ):
        if forbidden in workspace:
            raise ValidationError(
                "Workspace resolves a Global Library family through a compiled seed catalog: "
                + forbidden
            )

    global_library = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/GlobalLibrary.swift"
    ).read_text(encoding="utf-8")
    for required in (
        "var devices: [LibraryItem<DeviceDefinition>]",
        "var coverGlasses: [LibraryItem<CoverGlassDefinition>]",
        "var cameras: [LibraryItem<CameraProfileDefinition>]",
        "var lenses: [LibraryItem<LensProfileDefinition>]",
        "var environments: [LibraryItem<EnvironmentProfileDefinition>]",
        "document.renderPresets.map(\\.value)",
    ):
        if required not in global_library:
            raise ValidationError(
                f"Global Library omits a current typed family or overlays a seed catalog: {required}"
            )

    profile_source = (
        ROOT / "crates/screen-application/src/test_authoring.rs"
    ).read_text(encoding="utf-8")
    for required in (
        "fn device<'a>",
        "fn cover<'a>",
        "fn capture<'a>",
        "fn lens<'a>",
        "fn environment<'a>",
    ):
        if required not in profile_source:
            raise ValidationError(
                f"Application profile source omits one Global Library family: {required}"
            )
    apply = re.search(
        r"private func applySceneAuthoring\(.*?\n    }\n\n    private func restoreImportedPhysicalState",
        workspace,
        flags=re.DOTALL,
    )
    if not apply:
        raise ValidationError("Saved Scene application boundary is missing")
    for required in (
        "globalLibraryStore.load()",
        "authoring.profiles.deviceID",
        "authoring.profiles.coverGlassID",
        "materializeSceneSelection(",
        "authoring.overrides",
        "profileDevice: sceneDevice",
        "profileCoverGlass: sceneCoverGlass",
    ):
        if required not in apply.group(0):
            raise ValidationError(
                f"Saved Scene does not resolve current profiles before overrides: {required}"
            )
    materialize = re.search(
        r"private func materializeSceneSelection\(.*?\n    }\n\n    private func sceneProfileBaselines",
        workspace,
        flags=re.DOTALL,
    )
    if not materialize:
        raise ValidationError("Saved Scene profile materializer is missing")
    for forbidden in ("?? builtInDevices.first", "?? RustDeviceCatalog.builtIns().first"):
        if forbidden in materialize.group(0):
            raise ValidationError(
                "Saved Scene substitutes another Device identity during profile materialization"
            )

    refresh = re.search(
        r"func refreshActiveSceneFromGlobalLibrary\(\).*?\n    }\n\n    var pipelineSummary",
        workspace,
        flags=re.DOTALL,
    )
    if not refresh:
        raise ValidationError("Global Library edits do not rematerialize the active scene")
    for required in (
        "currentSceneAuthoringDocument(",
        "globalLibraryStore.load()",
        "RustTestAuthoringProfileContext(library: library)",
        "materializeSceneSelection(",
        "profileDevice: device",
        "profileCoverGlass: coverGlass",
        "restoreSceneOverrides(authoring.modelOverrides)",
        "explicitSceneOverrideControlIDs",
        "rebuildPhysicalSelectedFrame()",
    ):
        if required not in refresh.group(0):
            raise ValidationError(
                "Active scene library refresh omits complete rematerialization: " + required
            )
    content = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/ContentView.swift"
    ).read_text(encoding="utf-8")
    if ".onChange(of: library.document)" not in content or (
        "model.refreshActiveSceneFromGlobalLibrary()" not in content
    ):
        raise ValidationError("Global Library publication is not connected to active-scene refresh")

    commit = re.search(
        r"private func commitSceneAuthoringEdit\(.*?\n    }\n\n    private func restoreSceneAuthoringEdit",
        workspace,
        flags=re.DOTALL,
    )
    if not commit or "explicitSceneOverrideControlIDs.formUnion(controlIDs)" not in commit.group(0):
        raise ValidationError(
            "Cards and gizmos do not share one scene-authoring override transaction"
        )
    capture = re.search(
        r"private func currentSceneControlOverrides\(\).*?\n    }\n\n    private func currentSceneModelOverrides",
        workspace,
        flags=re.DOTALL,
    )
    if not capture or "guard explicitSceneOverrideControlIDs.contains(descriptor.id)" not in capture.group(0):
        raise ValidationError("Saved Scene infers overrides instead of storing explicit edits")
    for function_name in (
        "endFocusTargetDrag",
        "endEnvironmentNavigation",
        "commitCameraNavigationPose",
        "commitDeviceNavigationPose",
        "placeDevice",
        "commitReferenceMatch",
    ):
        block = re.search(
            rf"(?:private )?func {function_name}\(.*?\n    }}",
            workspace,
            flags=re.DOTALL,
        )
        if not block or "commitSceneAuthoringEdit(" not in block.group(0):
            raise ValidationError(
                f"Interactive editor bypasses scene-authoring transaction: {function_name}"
            )


def validate_exact_temporal_inputs() -> None:
    engine = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/PhysicalMetalFrameEngine.swift"
    ).read_text(encoding="utf-8")
    workspace = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/WorkspaceModel.swift"
    ).read_text(encoding="utf-8")
    bridge = (ROOT / "crates/screen-native-bridge/src/lib.rs").read_text(encoding="utf-8")
    resolver = (
        ROOT / "crates/screen-application/src/scene_resolution.rs"
    ).read_text(encoding="utf-8")
    preparation = (
        ROOT / "crates/screen-application/src/render_preparation.rs"
    ).read_text(encoding="utf-8")
    temporal_cache = (
        ROOT / "crates/screen-application/src/temporal_cache.rs"
    ).read_text(encoding="utf-8")
    if "screen_physical_temporal_sample_requirements_v1" in bridge:
        raise ValidationError("bridge restored the independent temporal schedule API")
    for retired in (
        "raw.scene_resolver =",
        "raw.shutter_open_numerator =",
        "raw.render_full_width =",
    ):
        if retired in engine:
            raise ValidationError(
                "macOS submit can bypass opaque PreparedRender through: " + retired
            )
    for required in (
        "func prepare(",
        "PhysicalPreparedRender",
        "temporalInputs: [PhysicalTemporalInput]",
        "ScreenPhysicalTimedInputSampleV2",
        "SCREEN_PHYSICAL_SOURCE_SAMPLE_EXACT",
    ):
        if required not in engine:
            raise ValidationError("macOS host omits exact temporal input contract: " + required)
    for required in (
        "physicalEngine.prepare(",
        "preparedRender.temporalRequirements",
        "renderFrame(at: requirement.time)",
        "temporalInputs: temporalInputs",
    ):
        if required not in workspace:
            raise ValidationError("physical submit freezes nominal media during shutter: " + required)
    for required in (
        "screen_prepared_render_v1_create",
        "screen_prepared_render_v1_temporal_requirements",
        "prepare_capture_render(",
        "source sampling policy cannot resolve an exact prepared sample time",
    ):
        if required not in bridge:
            raise ValidationError("Application temporal preparation is incomplete: " + required)
    for required in (
        "TemporalArtifactKey",
        "scene_revision",
        "time_numerator",
        "active_origin_x",
        "render_origin_x",
        "TemporalQualityIdentity",
        "TemporalBackendIdentity",
        "WORKSTATION_RESOLVED_SCENE_CACHE_BYTES",
        "get_or_try_insert_with",
    ):
        if required not in temporal_cache:
            raise ValidationError("Application temporal cache identity is incomplete: " + required)
    if "resolve_prepared_at(" not in resolver or "self.temporal_cache" not in resolver:
        raise ValidationError("resolved scene samples do not consume the Application cache")
    if "resolver.resolve_prepared_at(" not in preparation:
        raise ValidationError("PreparedRender bypasses the exact temporal cache")
    for required in (
        "CachedSceneResolver",
        "cachedSceneResolver.revision == revision",
        "cachedSceneResolver.frameRate == exactFrameRate",
        "cachedSceneResolver.temporalSamplesOverride == temporalSamplesOverride",
    ):
        if required not in workspace:
            raise ValidationError("workstation does not retain the exact scene resolver: " + required)


def validate_setup_diagnostic_boundary() -> None:
    application = (
        ROOT / "crates/screen-application/src/setup_diagnostics.rs"
    ).read_text(encoding="utf-8")
    renderer = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/SetupFramingRenderer.swift"
    ).read_text(encoding="utf-8")
    workspace = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/WorkspaceModel.swift"
    ).read_text(encoding="utf-8")
    resolver = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/RustSceneFrameResolver.swift"
    ).read_text(encoding="utf-8")
    for required in (
        "pub struct SetupDiagnosticIdentity",
        "pub struct SetupDiagnosticPlan",
        "pub fn prepare_setup_diagnostic",
    ):
        if required not in application:
            raise ValidationError("Application Setup plan is incomplete: " + required)
    for forbidden in (
        "PhysicalPipelineAuthoringState",
        "DeviceDefinition",
        "authoredOverride",
    ):
        if forbidden in renderer:
            raise ValidationError(
                "Setup renderer can receive mutable host semantics: " + forbidden
            )
    for required in (
        "plan: ScreenSetupDiagnosticPlanV1",
        "screen_scene_setup_diagnostic_v1_prepare",
    ):
        if required not in renderer + resolver:
            raise ValidationError("host omits the closed Setup plan boundary: " + required)
    for required in (
        "publishedResolvedSceneFrame = scene",
        "let resolved = publishedResolvedSceneFrame",
        "currentFrame, authoredOverride: authoredOverride",
        "publishSceneFrame(result.frame, scene: resolved)",
    ):
        if required not in workspace:
            raise ValidationError(
                "Setup texture and overlay do not share one resolved identity: " + required
            )


def validate_test_inspector_hierarchy() -> None:
    application = (ROOT / "crates/screen-application/src/test_authoring.rs").read_text(
        encoding="utf-8"
    )
    presentation = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationPresentation/TestPresentation.swift"
    ).read_text(encoding="utf-8")
    mac_ui = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationMacUI/TestAuthoringView.swift"
    ).read_text(encoding="utf-8")
    coordinator = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenSimulationNative/TestAuthoringCoordinator.swift"
    ).read_text(encoding="utf-8")
    for required in (
        "pub struct TestInspectorLocation",
        "pub fn test_inspector_location",
        "every_editable_control_has_one_application_owned_inspector_location",
    ):
        if required not in application:
            raise ValidationError("Application does not own inspector placement: " + required)
    for required in (
        "TestInspectorGroupPresentation",
        "TestInspectorSectionPresentation",
        "Set(inspectorControlIDs) == allControlIDs",
    ):
        if required not in presentation:
            raise ValidationError("inspector presentation contract is incomplete: " + required)
    for required in (
        "rawControl.inspector_group_id",
        "rawControl.inspector_section_id",
        "inspectorGroups(from: inspectorPlacements)",
    ):
        if required not in coordinator:
            raise ValidationError("host omitted Application inspector metadata: " + required)
    for required in (
        'Image(systemName: "chevron.right")',
        ".contentShape(Rectangle())",
        "TestInspectorSubcard",
        'TestPhaseCard(label: "General", initiallyExpanded: true)',
        "initiallyExpanded: Bool = false",
        "@State private var expanded = false",
    ):
        if required not in mac_ui:
            raise ValidationError("inspector disclosure contract is incomplete: " + required)
    for forbidden in (
        'phase.id == "relative-geometry"',
        'control.id.hasPrefix(',
    ):
        if forbidden in mac_ui:
            raise ValidationError("Swift inferred inspector ownership: " + forbidden)


def validate_interactive_device_background() -> None:
    native_root = (
        ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative"
    )
    background = (native_root / "InteractivePreviewBackground.swift").read_text(
        encoding="utf-8"
    )
    renderer = (native_root / "SetupFramingRenderer.swift").read_text(encoding="utf-8")
    workspace = (native_root / "WorkspaceModel.swift").read_text(encoding="utf-8")
    content = (native_root / "ContentView.swift").read_text(encoding="utf-8")
    for required in (
        "case reference",
        "case vfxChecker",
        "case black",
        "case white",
        "case middleGray",
    ):
        if required not in background:
            raise ValidationError("interactive background omits option: " + required)
    for required in (
        "interactive_background(",
        "delivery_pixel / 32.0f",
        "float4(0.18f, 0.18f, 0.18f, 1)",
        "value.rgb + background.rgb * (1.0f - matte)",
        "background.rgb * (1.0f - matte)",
    ):
        if required not in renderer:
            raise ValidationError("interactive compositor omits contract: " + required)
    for required in (
        "interactivePreviewBackground",
        "changeInteractivePreviewBackground",
        "publishInteractiveComposite",
    ):
        if required not in workspace:
            raise ValidationError("Workspace omits interactive background: " + required)
    change_start = workspace.index("func changeInteractivePreviewBackground")
    change_end = workspace.index("func togglePlayback", change_start)
    change_body = workspace[change_start:change_end]
    if "physicalModel.invalidateExternalParameters()" not in change_body:
        raise ValidationError(
            "interactive background changes must invalidate Native and return to Setup"
        )
    if "InteractivePreviewBackground.allCases" not in content:
        raise ValidationError("Preview toolbar omits the background combo")
    queue_start = workspace.index("private func renderQueuedSceneFrame(")
    queue_end = workspace.index("func makeFusionPackageRequest(", queue_start)
    if "interactivePreviewBackground" in workspace[queue_start:queue_end]:
        raise ValidationError("Render Queue consumes workstation Preview background")
def main() -> int:
    try:
        paths = repository_paths()
        validate_decision_authority(ROOT)
        validate_domains()
        validate_swift_domains()
        validate_path_owners(paths)
        validate_archive_isolation(paths)
        validate_retired_surfaces(paths)
        validate_native_backend_composition(paths)
        validate_presentation_boundaries()
        validate_native_model_authority()
        validate_scene_self_containment()
        validate_fusion_scene_color_contract()
        validate_scene_profile_authority()
        validate_exact_temporal_inputs()
        validate_setup_diagnostic_boundary()
        validate_test_inspector_hierarchy()
        validate_interactive_device_background()
        validate_phase_gated_workflow()
    except (ValidationError, DecisionAuthorityError, json.JSONDecodeError) as error:
        print(f"architecture validation failed: {error}", file=sys.stderr)
        return 1
    print("architecture validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
