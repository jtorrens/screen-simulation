#!/usr/bin/env python3
"""One-way selected maintenance migration from scene library v13 to v14."""

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
OLD_SELECTION_KEYS = {
    "coverGlowScatterFraction", "coverGlowCoreRadiusMillimeters",
    "coverGlowTailRadiusMillimeters", "coverGlowTailFraction",
}
OLD_COVER_KEYS = {
    "glowScatterFraction", "glowCoreRadiusMillimeters",
    "glowTailRadiusMillimeters", "glowTailFraction",
}


def fail(message: str) -> None:
    raise ValueError(message)


def replace_glow_fields(container: dict, old: set[str], selection: bool) -> None:
    if not old.issubset(container):
        fail("El contrato v13 no contiene el Glow completo que debe migrarse.")
    new_intensity = "coverGlowIntensity" if selection else "glowIntensity"
    new_radius = "coverGlowRadiusMillimeters" if selection else "glowRadiusMillimeters"
    if new_intensity in container or new_radius in container:
        fail("El contrato v13 ya contiene campos exclusivos de v14.")
    scatter = "coverGlowScatterFraction" if selection else "glowScatterFraction"
    tail_radius = "coverGlowTailRadiusMillimeters" if selection else "glowTailRadiusMillimeters"
    container[new_intensity] = container[scatter]
    container[new_radius] = container[tail_radius]
    for key in old:
        del container[key]


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS:
        fail("La biblioteca seleccionada no tiene la forma estricta v13.")
    if document.get("schemaVersion") != 13:
        fail("La biblioteca seleccionada no declara el contrato v13.")
    scenes = document.get("scenes")
    if not isinstance(scenes, list):
        fail("La lista de escenas v13 no es válida.")

    for scene in scenes:
        if not isinstance(scene, dict) or set(scene) != SCENE_KEYS:
            fail("Un registro de escena v13 no es válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or set(snapshot) != SNAPSHOT_KEYS:
            fail("Un snapshot v13 no tiene la forma estricta requerida.")
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v13":
            fail("Un snapshot no declara SavedScene v13.")
        encoded = snapshot.get("settingsDocument")
        if not isinstance(encoded, str):
            fail("Un snapshot v13 no contiene settingsDocument.")
        try:
            settings_document = json.loads(base64.b64decode(encoded, validate=True))
        except (ValueError, json.JSONDecodeError) as error:
            fail(f"Un settingsDocument v24 no es legible: {error}")
        if not isinstance(settings_document, dict) or set(settings_document) != {"settings"}:
            fail("Un settingsDocument v24 no tiene la raíz estricta requerida.")
        settings = settings_document.get("settings")
        if not isinstance(settings, dict) or settings.get("schema") != "ScreenSimulation.FrameSettings.v24":
            fail("Un settingsDocument no declara FrameSettings v24.")
        context = settings.get("context")
        selection = context.get("selection") if isinstance(context, dict) else None
        pipeline = settings.get("pipeline")
        cover = pipeline.get("coverGlass") if isinstance(pipeline, dict) else None
        if not isinstance(selection, dict) or not isinstance(cover, dict):
            fail("Un settingsDocument v24 no contiene selección y Cover Glass explícitos.")
        replace_glow_fields(selection, OLD_SELECTION_KEYS, True)
        replace_glow_fields(cover, OLD_COVER_KEYS, False)
        settings["schema"] = "ScreenSimulation.FrameSettings.v25"
        snapshot["settingsDocument"] = base64.b64encode(
            json.dumps(settings_document, separators=(",", ":"), sort_keys=True).encode("utf-8")
        ).decode("ascii")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v14"

    document["schemaVersion"] = 14
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
    parser = argparse.ArgumentParser(description="Migra Scenes.v13.json al contrato v14 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
