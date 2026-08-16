#!/usr/bin/env python3
"""One-way selected maintenance migration from scene library v10 to v11."""

import argparse
import base64
import json
import os
from pathlib import Path


ROOT_KEYS = {"schemaVersion", "scenes"}
SCENE_KEYS = {"id", "name", "snapshot", "thumbnailFileName"}
SNAPSHOT_KEYS = {
    "schema",
    "source",
    "currentFrame",
    "viewerZoom",
    "viewerPanX",
    "viewerPanY",
    "viewerIsFitted",
    "settingsDocument",
    "generatedEnvironment",
    "tracking",
}


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS:
        fail("La biblioteca seleccionada no tiene la forma estricta v10.")
    if document.get("schemaVersion") != 10:
        fail("La biblioteca seleccionada no declara el contrato v10.")
    scenes = document.get("scenes")
    if not isinstance(scenes, list):
        fail("La lista de escenas v10 no es válida.")

    for scene in scenes:
        if not isinstance(scene, dict) or set(scene) != SCENE_KEYS:
            fail("Un registro de escena v10 no es válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or set(snapshot) != SNAPSHOT_KEYS:
            fail("Un snapshot v10 no tiene la forma estricta requerida.")
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v10":
            fail("Un snapshot no declara SavedScene v10.")
        encoded = snapshot.get("settingsDocument")
        if not isinstance(encoded, str):
            fail("Un snapshot v10 no contiene settingsDocument.")
        try:
            raw_settings = base64.b64decode(encoded, validate=True)
            settings_document = json.loads(raw_settings)
        except (ValueError, json.JSONDecodeError) as error:
            fail(f"Un settingsDocument v21 no es legible: {error}")
        if not isinstance(settings_document, dict) or set(settings_document) != {"settings"}:
            fail("Un settingsDocument v21 no tiene la raíz estricta requerida.")
        settings = settings_document.get("settings")
        if not isinstance(settings, dict) or settings.get("schema") != "ScreenSimulation.FrameSettings.v21":
            fail("Un settingsDocument no declara FrameSettings v21.")
        context = settings.get("context")
        selection = context.get("selection") if isinstance(context, dict) else None
        if not isinstance(selection, dict):
            fail("Un settingsDocument v21 no contiene su selección resuelta.")
        if "deviceVfxAlphaModeID" in selection:
            fail("La selección v21 ya contiene el campo exclusivo de v22.")

        # v21 ignored source alpha. This explicit maintenance value preserves
        # the authored image; new v22 authoring has its own independent default.
        selection["deviceVfxAlphaModeID"] = "ignore"
        settings["schema"] = "ScreenSimulation.FrameSettings.v22"
        snapshot["settingsDocument"] = base64.b64encode(
            json.dumps(
                settings_document,
                separators=(",", ":"),
                sort_keys=True,
                ensure_ascii=False,
            ).encode("utf-8")
        ).decode("ascii")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v11"

    document["schemaVersion"] = 11
    return document


def migrate(source: Path, destination: Path) -> None:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    document = migrated_document(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Migra una biblioteca seleccionada Scenes.v10.json al contrato v11 actual."
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
