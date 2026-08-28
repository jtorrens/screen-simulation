#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v25 to v26."""

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
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v25.")
    if document.get("schemaVersion") != 25 or not isinstance(document.get("scenes"), list):
        raise ValueError("La Biblioteca seleccionada no declara el contrato v25.")
    result = copy.deepcopy(document)
    for scene in result["scenes"]:
        if not isinstance(scene, dict) or not isinstance(scene.get("snapshot"), dict):
            raise ValueError("Una escena v25 no contiene snapshot.")
        snapshot = scene["snapshot"]
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v24" \
                or "trackingSceneMethod" in snapshot \
                or "fusionTrackerMotion" not in snapshot:
            raise ValueError("Una escena no contiene SavedScene v24 estricto.")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v25"
        snapshot["trackingSceneMethod"] = (
            "fusionTrackerClipboard"
            if snapshot["fusionTrackerMotion"] is not None
            else "fusionComposition"
        )
    result["schemaVersion"] = 26
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v25.json al contrato v26 actual.")
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
