#!/usr/bin/env python3
"""One-way maintenance migration from the selected scene library v7 to v8."""

import argparse
import base64
import json
import os
from pathlib import Path


ROOT_KEYS = {"schemaVersion", "scenes"}
SCENE_KEYS = {"id", "name", "snapshot", "thumbnailFileName"}


def migrate(source: Path, destination: Path) -> None:
    if destination.exists():
        raise SystemExit(f"El destino ya existe: {destination}")
    document = json.loads(source.read_text(encoding="utf-8"))
    if set(document) != ROOT_KEYS or document.get("schemaVersion") != 7:
        raise SystemExit("La biblioteca seleccionada no es el contrato estricto v7.")
    scenes = document.get("scenes")
    if not isinstance(scenes, list):
        raise SystemExit("La lista de escenas v7 no es válida.")
    for scene in scenes:
        if not isinstance(scene, dict) or set(scene) != SCENE_KEYS:
            raise SystemExit("Un registro de escena v7 no es válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or snapshot.get("schema") != "ScreenSimulation.SavedScene.v7":
            raise SystemExit("Un snapshot no declara el contrato v7.")
        encoded = snapshot.get("settingsDocument")
        if not isinstance(encoded, str):
            raise SystemExit("Un snapshot v7 no contiene settingsDocument.")
        settings_document = json.loads(base64.b64decode(encoded, validate=True))
        settings = settings_document.get("settings")
        if not isinstance(settings, dict) or settings.get("schema") != "ScreenSimulation.FrameSettings.v18":
            raise SystemExit("Un settingsDocument no declara FrameSettings v18.")
        context = settings.get("context")
        selection = context.get("selection") if isinstance(context, dict) else None
        pipeline = settings.get("pipeline")
        if not isinstance(selection, dict) or not isinstance(pipeline, dict):
            raise SystemExit("Un settingsDocument no contiene selección y pipeline resueltos.")
        if "moireSaturation" in selection or "moireSaturation" in pipeline:
            raise SystemExit("El documento v18 ya contiene campos del contrato v19.")
        selection["moireSaturation"] = 1.0
        pipeline["moireSaturation"] = 1.0
        settings["schema"] = "ScreenSimulation.FrameSettings.v19"
        snapshot["settingsDocument"] = base64.b64encode(
            json.dumps(settings_document, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        ).decode("ascii")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v8"
    document["schemaVersion"] = 8
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    migrate(args.source.resolve(), args.destination.resolve())


if __name__ == "__main__":
    main()
