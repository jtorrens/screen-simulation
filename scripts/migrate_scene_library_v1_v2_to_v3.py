#!/usr/bin/env python3
"""Explicit one-way migration for a selected scene-library copy.

Normal application startup never imports or calls this module.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import shutil
import sys
import uuid
from pathlib import Path


CURRENT_LIBRARY_VERSION = 3
CURRENT_SCENE_SCHEMA = "ScreenSimulation.SavedScene.v3"
CURRENT_SETTINGS_SCHEMA = "ScreenSimulation.FrameSettings.v16"
CANONICAL_STAGE_IDS = [
    0x101, 0x102, 0x108, 0x103, 0x104, 0x201, 0x105, 0x106,
    0x107, 0x202, 0x203, 0x208, 0x204, 0x207, 0x205, 0x206,
]
PREVIEW_PHASE_RENAMES = {
    "sensor-cfa": "sensor-collection",
    "sensor-noise": "sensor-readout-raw",
}


class MigrationError(RuntimeError):
    pass


def require_keys(value: object, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != keys:
        raise MigrationError(f"{label} no coincide con el contrato retirado esperado")
    return value


def positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise MigrationError(f"{label} debe ser un entero positivo")
    return value


def exact_rate(value: object, label: str) -> dict[str, int]:
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return {"numerator": value, "denominator": 1}
    if isinstance(value, dict):
        rate = require_keys(value, {"numerator", "denominator"}, label)
        return {
            "numerator": positive_integer(rate["numerator"], f"{label}.numerator"),
            "denominator": positive_integer(rate["denominator"], f"{label}.denominator"),
        }
    raise MigrationError(
        f"{label} no es racional exacto ni una cadencia entera materializable"
    )


def migrate_settings(encoded: str) -> str:
    try:
        raw = base64.b64decode(encoded, validate=True)
        document = json.loads(raw)
    except Exception as error:
        raise MigrationError("settingsDocument no es JSON Base64 válido") from error
    root = require_keys(document, {"settings"}, "settingsDocument")
    settings = root["settings"]
    if not isinstance(settings, dict):
        raise MigrationError("settingsDocument.settings no es un objeto")
    retired_schema = settings.get("schema")
    if retired_schema not in {
        "ScreenSimulation.FrameSettings.v14",
        "ScreenSimulation.FrameSettings.v15",
    }:
        raise MigrationError(f"esquema de settings no migrable: {retired_schema!r}")
    context = settings.get("context")
    if not isinstance(context, dict) or not isinstance(context.get("selection"), dict):
        raise MigrationError("settingsDocument no contiene la selección requerida")
    selection = context["selection"]
    selection["frameRate"] = exact_rate(selection.get("frameRate"), "frameRate")
    phase = context.get("previewPhaseID")
    if not isinstance(phase, str):
        raise MigrationError("previewPhaseID no es una identidad estable")
    context["previewPhaseID"] = PREVIEW_PHASE_RENAMES.get(phase, phase)

    stages = settings.get("stages")
    if not isinstance(stages, list) or len(stages) != len(CANONICAL_STAGE_IDS):
        raise MigrationError("la lista retirada de fases no está completa")
    migrated_by_id: dict[int, dict] = {}
    for raw_stage in stages:
        if not isinstance(raw_stage, dict) or isinstance(raw_stage.get("stageID"), bool):
            raise MigrationError("una fase retirada no tiene identidad válida")
        stage = dict(raw_stage)
        stage_id = stage.get("stageID")
        if not isinstance(stage_id, int):
            raise MigrationError("una fase retirada no tiene identidad entera")
        if retired_schema == "ScreenSimulation.FrameSettings.v14":
            if stage_id == 0x204:
                if stage.get("kind") != "discrete":
                    raise MigrationError("Sensor CFA retirado no conserva su contrato discreto")
                stage_id = 0x205
            elif stage_id == 0x205:
                if stage.get("kind") != "continuous":
                    raise MigrationError("Sensor Noise retirado no conserva su contrato continuo")
                stage_id = 0x204
        stage["stageID"] = stage_id
        if stage_id in migrated_by_id:
            raise MigrationError("la migración produciría identidades de fase duplicadas")
        migrated_by_id[stage_id] = stage
    if set(migrated_by_id) != set(CANONICAL_STAGE_IDS):
        raise MigrationError("las fases retiradas no cubren el contrato actual")
    settings["stages"] = [migrated_by_id[stage_id] for stage_id in CANONICAL_STAGE_IDS]
    settings["schema"] = CURRENT_SETTINGS_SCHEMA
    return base64.b64encode(
        json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")


def migrate_missing_media(source: dict) -> None:
    missing = source.get("missingMedia")
    if missing is None:
        return
    if not isinstance(missing, dict):
        raise MigrationError("missingMedia no es un objeto")
    if "frameRate" in missing:
        old = require_keys(
            missing,
            {"originalName", "width", "height", "frameRate", "frameCount", "durationSeconds"},
            "missingMedia v1",
        )
        rate = exact_rate(old["frameRate"], "missingMedia.frameRate")
        frame_count = positive_integer(old["frameCount"], "missingMedia.frameCount")
        duration = old["durationSeconds"]
        expected = frame_count * rate["denominator"] / rate["numerator"]
        if not isinstance(duration, (int, float)) or not math.isfinite(duration):
            raise MigrationError("missingMedia.durationSeconds no es finito")
        if abs(float(duration) - expected) > max(1e-9, expected * 1e-9):
            raise MigrationError("durationSeconds no coincide con frameCount/frameRate")
        source["missingMedia"] = {
            "originalName": old["originalName"],
            "width": positive_integer(old["width"], "missingMedia.width"),
            "height": positive_integer(old["height"], "missingMedia.height"),
            "frameRateNumerator": rate["numerator"],
            "frameRateDenominator": rate["denominator"],
            "frameCount": frame_count,
            "durationNumerator": frame_count * rate["denominator"],
            "durationDenominator": rate["numerator"],
        }
    else:
        current_keys = {
            "originalName", "width", "height", "frameRateNumerator",
            "frameRateDenominator", "frameCount", "durationNumerator",
            "durationDenominator",
        }
        require_keys(missing, current_keys, "missingMedia v2")
        for key in current_keys - {"originalName"}:
            positive_integer(missing[key], f"missingMedia.{key}")


def migrate_scene(scene: object, source_directory: Path) -> dict:
    scene = require_keys(scene, {"id", "name", "thumbnailFileName", "snapshot"}, "scene")
    try:
        scene_id = uuid.UUID(scene["id"])
    except Exception as error:
        raise MigrationError("una escena no tiene UUID válido") from error
    expected_thumbnail = f"{str(scene_id).lower()}.png"
    if scene["thumbnailFileName"] != expected_thumbnail:
        raise MigrationError("la miniatura no corresponde a la identidad de escena")
    thumbnail = source_directory / expected_thumbnail
    if not thumbnail.is_file() or not thumbnail.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
        raise MigrationError(f"miniatura PNG obligatoria ausente: {expected_thumbnail}")
    snapshot = require_keys(
        scene["snapshot"],
        {"schema", "source", "currentFrame", "viewerZoom", "viewerPanX", "viewerPanY",
         "viewerIsFitted", "settingsDocument"},
        "snapshot",
    )
    if snapshot["schema"] not in {
        "ScreenSimulation.SavedScene.v1", "ScreenSimulation.SavedScene.v2"
    }:
        raise MigrationError(f"snapshot no migrable: {snapshot['schema']!r}")
    if not isinstance(snapshot["source"], dict):
        raise MigrationError("source no es un objeto")
    migrate_missing_media(snapshot["source"])
    snapshot["settingsDocument"] = migrate_settings(snapshot["settingsDocument"])
    snapshot["schema"] = CURRENT_SCENE_SCHEMA
    return scene


def migrate(source_directory: Path, destination_directory: Path) -> Path:
    if not source_directory.is_dir():
        raise MigrationError("la biblioteca seleccionada no existe")
    if destination_directory.exists():
        raise MigrationError("el destino debe ser nuevo y estar vacío")
    indexes = [path for version in (1, 2) if (path := source_directory / f"Scenes.v{version}.json").is_file()]
    if len(indexes) != 1:
        raise MigrationError("debe existir exactamente un índice retirado v1 o v2")
    try:
        document = json.loads(indexes[0].read_text(encoding="utf-8"))
    except Exception as error:
        raise MigrationError("el índice retirado no es JSON válido") from error
    root = require_keys(document, {"schemaVersion", "scenes"}, "biblioteca")
    if root["schemaVersion"] not in (1, 2) or not isinstance(root["scenes"], list):
        raise MigrationError("la versión de biblioteca no coincide con su índice")
    if root["schemaVersion"] != int(indexes[0].stem.removeprefix("Scenes.v")):
        raise MigrationError("el nombre y la versión del índice no coinciden")
    migrated = [migrate_scene(scene, source_directory) for scene in root["scenes"]]
    destination_directory.mkdir(parents=True)
    for scene in migrated:
        shutil.copy2(source_directory / scene["thumbnailFileName"], destination_directory)
    output = destination_directory / "Scenes.v3.json"
    output.write_text(
        json.dumps({"schemaVersion": CURRENT_LIBRARY_VERSION, "scenes": migrated},
                   ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_directory", type=Path)
    parser.add_argument("destination_directory", type=Path)
    args = parser.parse_args()
    try:
        output = migrate(args.source_directory.resolve(), args.destination_directory.resolve())
    except MigrationError as error:
        print(f"migration failed: {error}", file=sys.stderr)
        return 2
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
