#!/usr/bin/env python3
"""One-way selected maintenance migration from scene library v14 to v15."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path


ROOT_KEYS = {"schemaVersion", "scenes"}
SCENE_KEYS = {"id", "name", "snapshot", "thumbnailFileName"}
SNAPSHOT_KEYS = {
    "schema", "source", "currentFrame", "viewerZoom", "viewerPanX",
    "viewerPanY", "viewerIsFitted", "settingsDocument",
    "generatedEnvironment", "tracking",
}


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS:
        fail("La biblioteca seleccionada no tiene la forma estricta v14.")
    if document.get("schemaVersion") != 14:
        fail("La biblioteca seleccionada no declara el contrato v14.")
    scenes = document.get("scenes")
    if not isinstance(scenes, list):
        fail("La lista de escenas v14 no es válida.")

    for scene in scenes:
        if not isinstance(scene, dict) or set(scene) != SCENE_KEYS:
            fail("Un registro de escena v14 no es válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or set(snapshot) != SNAPSHOT_KEYS:
            fail("Un snapshot v14 no tiene la forma estricta requerida.")
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v14":
            fail("Un snapshot no declara SavedScene v14.")
        encoded = snapshot.get("settingsDocument")
        if not isinstance(encoded, str):
            fail("Un snapshot v14 no contiene settingsDocument.")
        try:
            settings_document = json.loads(base64.b64decode(encoded, validate=True))
        except (ValueError, json.JSONDecodeError) as error:
            fail(f"Un settingsDocument v25 no es legible: {error}")
        if not isinstance(settings_document, dict) or set(settings_document) != {"settings"}:
            fail("Un settingsDocument v25 no tiene la raíz estricta requerida.")
        settings = settings_document.get("settings")
        if not isinstance(settings, dict) or settings.get("schema") != "ScreenSimulation.FrameSettings.v25":
            fail("Un settingsDocument no declara FrameSettings v25.")
        context = settings.get("context")
        selection = context.get("selection") if isinstance(context, dict) else None
        pipeline = settings.get("pipeline")
        if not isinstance(selection, dict) or not isinstance(pipeline, dict):
            fail("Un settingsDocument v25 no contiene selección y pipeline explícitos.")
        if "coverGlowExteriorIntensity" in selection or "coverGlowExteriorIntensity" in pipeline:
            fail("Un settingsDocument v25 ya contiene el Spill exterior v15.")
        selection["coverGlowExteriorIntensity"] = 1.0
        pipeline["coverGlowExteriorIntensity"] = 1.0
        settings["schema"] = "ScreenSimulation.FrameSettings.v26"
        snapshot["settingsDocument"] = base64.b64encode(
            json.dumps(settings_document, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ).decode("ascii")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v15"

    document["schemaVersion"] = 15
    return document


def migrate(source: Path, destination: Path) -> None:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    document = migrated_document(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v14.json al contrato v15 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
