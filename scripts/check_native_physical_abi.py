#!/usr/bin/env python3
"""Reject retired physical ABI surfaces from the native macOS product."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ACTIVE_ROOTS = (
    ROOT / "apps" / "screen-native-macos",
    ROOT / "crates" / "screen-native-bridge",
)
RETIRED_FILES = (
    ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/DeviceMetalStage.swift",
    ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/PhysicalPipeline.swift",
    ROOT / "apps/screen-native-macos/Sources/ScreenSimulationNative/Resources/DeviceStage.metal",
    ROOT / "crates/screen-platform/src/flat_panel_metal.rs",
    ROOT / "crates/screen-platform/shaders/flat_panel.metal",
)
RETIRED_TOKENS = (
    "ScreenPhysicalFrameRequestV1",
    "ScreenPhysicalFrameResultV1",
    "ScreenPhysicalStageContributionV1",
    "screen_physical_pipeline_process_rgba32f",
    "ScreenPhysicalFrameInputRef",
    "screen_physical_frame_input_create",
    "capture_amount",
    "ScreenTestAuthoringSelectionV4",
    "ScreenTestControlDescriptorV2",
    "SCREEN_TEST_AUTHORING_ABI_VERSION 4",
    "ScreenTestAuthoringSelectionV7",
    "ScreenTestControlDescriptorV3",
    "SCREEN_TEST_AUTHORING_ABI_VERSION 7",
    "ScreenTestAuthoringSelectionV8",
    "ScreenTestControlDescriptorV4",
    "SCREEN_TEST_AUTHORING_ABI_VERSION 8",
    "SCREEN_TEST_AUTHORING_ABI_VERSION 9",
    "ScreenTestAuthoringSelectionV9",
    "ScreenCapturePresetParametersV1",
    "SCREEN_AUTHORING_CATALOG_ABI_VERSION 2",
    "SCREEN_PHYSICAL_FRAME_ABI_VERSION 17",
    "SCREEN_TEST_AUTHORING_ABI_VERSION 29",
    "ScreenRecordingExecutionPlanV1",
)

RETIRED_SOURCE_PATTERNS = (
    r"#define\s+SCREEN_PHYSICAL_FRAME_ABI_VERSION\s+(?:1|4|5)u\b",
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


def validate_sources() -> None:
    present = [str(path.relative_to(ROOT)) for path in RETIRED_FILES if path.exists()]
    if present:
        raise RuntimeError(f"retired physical files remain active: {present}")
    for root in ACTIVE_ROOTS:
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in {".h", ".rs", ".swift", ".metal"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            matches = [token for token in RETIRED_TOKENS if token in text]
            matches.extend(
                pattern for pattern in RETIRED_SOURCE_PATTERNS if re.search(pattern, text)
            )
            if matches:
                raise RuntimeError(
                    f"retired physical ABI tokens in {path.relative_to(ROOT)}: {matches}"
                )
    header = (
        ROOT
        / "apps/screen-native-macos/Sources/ScreenPhysicalBridge/include/ScreenPhysicalBridge.h"
    ).read_text(encoding="utf-8")
    required = (
        "#define SCREEN_PHYSICAL_FRAME_ABI_VERSION 33u",
        "#define SCREEN_DEVICE_VFX_ALPHA_TRANSPARENCY 1u",
        "ScreenPhysicalFrameRequestV2",
        "ScreenPhysicalFrameResultV2",
        "screen_physical_frame_submit",
        "screen_physical_pipeline_snapshot_create",
        "ScreenPhysicalStageDescriptorV1",
        "screen_physical_stage_descriptor",
        "ScreenPhysicalStageContributionV3",
        "ScreenPhysicalTimedInputSetV2Ref",
        "screen_physical_timed_input_set_v2_create",
        "ScreenPhysicalCameraPoseTrackV2Ref",
        "ScreenPhysicalScreenPoseTrackV2Ref",
        "ScreenTrackingOverlayRequestV1",
        "screen_tracking_overlay_v1_resolve",
        "ScreenSceneFocusTargetRequestV1",
        "screen_scene_focus_target_v1_project",
        "screen_scene_focus_target_v1_unproject",
        "ScreenSceneEnvironmentRadiusRequestV1",
        "screen_scene_environment_minimum_radius_v1",
        "ScreenPreparedRenderV1Ref",
        "screen_prepared_render_v1_create",
        "screen_prepared_render_v1_temporal_requirements",
        "#define SCREEN_TEST_AUTHORING_ABI_VERSION 38u",
        "ScreenTestAuthoringSelectionV23",
        "ScreenTestPhaseDescriptorV5",
        "ScreenTestControlDescriptorV5",
        "#define SCREEN_AUTHORING_CATALOG_ABI_VERSION 9u",
        "ScreenCapturePresetParametersV4",
        "#define SCREEN_RECORDING_EXECUTION_PLAN_ABI_VERSION 2u",
        "ScreenRecordingExecutionPlanV2",
    )
    missing = [token for token in required if token not in header]
    if missing:
        raise RuntimeError(f"current physical ABI header is incomplete: {missing}")
    rust_bridge = (ROOT / "crates/screen-native-bridge/src/lib.rs").read_text(
        encoding="utf-8"
    )
    for token in (
        "SCREEN_PHYSICAL_FRAME_ABI_VERSION: u32 = 33",
        "SCREEN_DEVICE_VFX_ALPHA_TRANSPARENCY: u32 = 1",
        "ScreenPhysicalStageDescriptorV1",
        "screen_physical_stage_descriptor",
        "ScreenPhysicalStageContributionV3",
        "ScreenTrackingOverlayRequestV1",
        "screen_tracking_overlay_v1_resolve",
        "ScreenSceneFocusTargetRequestV1",
        "screen_scene_focus_target_v1_project",
        "screen_scene_focus_target_v1_unproject",
        "ScreenSceneEnvironmentRadiusRequestV1",
        "screen_scene_environment_minimum_radius_v1",
        "ScreenPreparedRenderV1",
        "screen_prepared_render_v1_create",
        "screen_prepared_render_v1_temporal_requirements",
        "SCREEN_TEST_AUTHORING_ABI_VERSION: u32 = 38",
        "ScreenTestAuthoringSelectionV23",
        "ScreenTestPhaseDescriptorV5",
        "ScreenTestControlDescriptorV5",
        "SCREEN_RECORDING_EXECUTION_PLAN_ABI_VERSION: u32 = 2",
        "ScreenRecordingExecutionPlanV2",
        "SCREEN_AUTHORING_CATALOG_ABI_VERSION: u32 = 9",
        "ScreenCapturePresetParametersV4",
    ):
        if token not in rust_bridge:
            raise RuntimeError(f"current Test ABI Rust contract is incomplete: {token}")


def validate_binary(binary: Path) -> None:
    if not binary.is_file():
        raise RuntimeError(f"native macOS binary does not exist: {binary}")
    symbols = capture(["nm", "-a", str(binary)])
    strings = capture(["strings", str(binary)])
    combined = symbols + "\n" + strings
    matches = [token for token in RETIRED_TOKENS if token in combined]
    if matches:
        raise RuntimeError(f"native binary contains retired physical ABI: {matches}")
    if "_screen_physical_frame_submit" not in symbols:
        raise RuntimeError("native binary does not contain the unified physical submit boundary")
    if "_screen_tracking_overlay_v1_resolve" not in symbols:
        raise RuntimeError("native binary does not contain the tracking overlay evaluator")
    if "_screen_scene_focus_target_v1_project" not in symbols:
        raise RuntimeError("native binary does not contain the focus target projector")
    if "_screen_scene_focus_target_v1_unproject" not in symbols:
        raise RuntimeError("native binary does not contain the focus target inverse projector")
    if "_screen_scene_environment_minimum_radius_v1" not in symbols:
        raise RuntimeError("native binary does not contain the environment radius evaluator")
    if "_screen_prepared_render_v1_create" not in symbols:
        raise RuntimeError("native binary does not contain opaque render preparation")
    if "_screen_prepared_render_v1_temporal_requirements" not in symbols:
        raise RuntimeError("native binary does not expose prepared exact temporal requirements")


def main() -> int:
    validate_sources()
    if len(sys.argv) > 2:
        raise RuntimeError("usage: check_native_physical_abi.py [EXECUTABLE]")
    if len(sys.argv) == 2:
        validate_binary(Path(sys.argv[1]).resolve())
    print("native macOS physical ABI v33 source/header/symbol gate passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"native physical ABI gate failed: {error}", file=sys.stderr)
        raise SystemExit(1)
