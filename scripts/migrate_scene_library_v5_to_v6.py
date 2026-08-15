#!/usr/bin/env python3
"""One-way maintenance migration for an explicitly selected scene library."""

import argparse
import json
import os
from pathlib import Path


ROOT_KEYS = {"schemaVersion", "scenes"}
SCENE_KEYS = {"id", "name", "snapshot", "thumbnailFileName"}
SNAPSHOT_V5_KEYS = {
    "schema", "source", "currentFrame", "viewerZoom", "viewerPanX",
    "viewerPanY", "viewerIsFitted", "settingsDocument", "generatedEnvironment",
}


def migrate(source: Path, destination: Path) -> None:
    if destination.exists():
        raise SystemExit(f"El destino ya existe: {destination}")
    document = json.loads(source.read_text(encoding="utf-8"))
    if set(document) != ROOT_KEYS or document.get("schemaVersion") != 5:
        raise SystemExit("La biblioteca seleccionada no es el contrato estricto v5.")
    scenes = document.get("scenes")
    if not isinstance(scenes, list):
        raise SystemExit("La lista de escenas v5 no es válida.")
    for scene in scenes:
        if not isinstance(scene, dict) or set(scene) != SCENE_KEYS:
            raise SystemExit("Un registro de escena v5 no es válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or set(snapshot) != SNAPSHOT_V5_KEYS:
            raise SystemExit("Un snapshot v5 no es válido.")
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v5":
            raise SystemExit("El snapshot no declara el contrato v5.")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v6"
        snapshot["tracking"] = None
    document["schemaVersion"] = 6

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
