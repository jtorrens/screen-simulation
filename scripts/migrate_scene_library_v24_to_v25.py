#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v24 to v25."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    }:
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v24.")
    if document.get("schemaVersion") != 24:
        raise ValueError("La Biblioteca seleccionada no declara el contrato v24.")
    result = copy.deepcopy(document)
    scenes = result.get("scenes")
    if not isinstance(scenes, list):
        raise ValueError("La colección de escenas v24 no es válida.")
    for scene in scenes:
        if not isinstance(scene, dict) or not isinstance(scene.get("snapshot"), dict):
            raise ValueError("Una escena v24 no contiene snapshot.")
        snapshot = scene["snapshot"]
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v23":
            raise ValueError("Una escena no declara SavedScene v23.")
        if "fusionTrackerMotion" in snapshot:
            raise ValueError("SavedScene v23 contiene un campo de tracking 2D desconocido.")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v24"
        snapshot["fusionTrackerMotion"] = None
    result["schemaVersion"] = 25
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v24.json al contrato v25 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        backup = migrate(args.source.resolve(), args.destination.resolve())
        print(f"Copia verificada: {backup}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
