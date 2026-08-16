#!/usr/bin/env python3
"""One-way selected maintenance migration from scene library v12 to v13."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path


BUILTIN_THRESHOLDS = {
    "cover-glossy-strong-ar": 0.20,
    "cover-glossy-standard-ar": 0.20,
    "cover-semi-gloss": 0.18,
    "cover-matte-ar": 0.15,
    "cover-heavy-matte": 0.12,
    "cover-thick-crt": 0.18,
}
ROOT_KEYS = {"schemaVersion", "scenes"}
SCENE_KEYS = {"id", "name", "snapshot", "thumbnailFileName"}
SNAPSHOT_KEYS = {
    "schema", "source", "currentFrame", "viewerZoom", "viewerPanX",
    "viewerPanY", "viewerIsFitted", "settingsDocument",
    "generatedEnvironment", "tracking",
}


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path, explicit_thresholds: dict[str, float] | None = None) -> dict:
    thresholds = {**BUILTIN_THRESHOLDS, **(explicit_thresholds or {})}
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS:
        fail("La biblioteca seleccionada no tiene la forma estricta v12.")
    if document.get("schemaVersion") != 12:
        fail("La biblioteca seleccionada no declara el contrato v12.")
    scenes = document.get("scenes")
    if not isinstance(scenes, list):
        fail("La lista de escenas v12 no es válida.")

    for scene in scenes:
        if not isinstance(scene, dict) or set(scene) != SCENE_KEYS:
            fail("Un registro de escena v12 no es válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or set(snapshot) != SNAPSHOT_KEYS:
            fail("Un snapshot v12 no tiene la forma estricta requerida.")
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v12":
            fail("Un snapshot no declara SavedScene v12.")
        encoded = snapshot.get("settingsDocument")
        if not isinstance(encoded, str):
            fail("Un snapshot v12 no contiene settingsDocument.")
        try:
            settings_document = json.loads(base64.b64decode(encoded, validate=True))
        except (ValueError, json.JSONDecodeError) as error:
            fail(f"Un settingsDocument v23 no es legible: {error}")
        if not isinstance(settings_document, dict) or set(settings_document) != {"settings"}:
            fail("Un settingsDocument v23 no tiene la raíz estricta requerida.")
        settings = settings_document.get("settings")
        if not isinstance(settings, dict) or settings.get("schema") != "ScreenSimulation.FrameSettings.v23":
            fail("Un settingsDocument no declara FrameSettings v23.")
        context = settings.get("context")
        selection = context.get("selection") if isinstance(context, dict) else None
        pipeline = settings.get("pipeline")
        cover = pipeline.get("coverGlass") if isinstance(pipeline, dict) else None
        if not isinstance(selection, dict) or not isinstance(cover, dict):
            fail("Un settingsDocument v23 no contiene selección y Cover Glass explícitos.")
        cover_id = selection.get("coverGlassPresetID")
        if cover_id != cover.get("id") or not isinstance(cover_id, str):
            fail("La selección y el Cover Glass no comparten una identidad explícita.")
        if "coverGlowThresholdRelativeWhite" in selection or "glowThresholdRelativeWhite" in cover:
            fail("El contrato v23 ya contiene campos exclusivos de v24.")
        if cover_id not in thresholds:
            fail(f"Falta un umbral explícito para el Cover Glass {cover_id!r}.")
        threshold = thresholds[cover_id]
        if not isinstance(threshold, (int, float)) or not 0.0 <= float(threshold) <= 1.0:
            fail(f"El umbral explícito de {cover_id!r} no es válido.")
        selection["coverGlowThresholdRelativeWhite"] = float(threshold)
        cover["glowThresholdRelativeWhite"] = float(threshold)
        settings["schema"] = "ScreenSimulation.FrameSettings.v24"
        snapshot["settingsDocument"] = base64.b64encode(
            json.dumps(settings_document, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ).decode("ascii")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v13"

    document["schemaVersion"] = 13
    return document


def migrate(source: Path, destination: Path, explicit_thresholds: dict[str, float] | None = None) -> None:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    document = migrated_document(source, explicit_thresholds)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v12.json al contrato v13 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument(
        "--threshold", action="append", default=[], metavar="COVER_ID=VALUE",
        help="Umbral explícito para un Cover Glass personalizado.",
    )
    args = parser.parse_args()
    explicit: dict[str, float] = {}
    try:
        for entry in args.threshold:
            identity, value = entry.rsplit("=", 1)
            explicit[identity] = float(value)
        migrate(args.source.resolve(), args.destination.resolve(), explicit)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
