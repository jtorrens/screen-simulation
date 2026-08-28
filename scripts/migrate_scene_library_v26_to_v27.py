#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v26 to v27."""

from __future__ import annotations

import argparse
import copy
import json
import uuid
from pathlib import Path

from migration_io import publish_with_source_backup


def animation_document(identity: str) -> dict:
    key_id = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"screen-simulation:simulation-opacity:{identity}:0/1",
    )
    return {
        "schema": "ScreenSimulation.SceneAnimation.v1",
        "scalarTracks": [{
            "propertyID": "simulation-opacity",
            "keyframes": [{
                "id": str(key_id),
                "timeNumerator": 0,
                "timeDenominator": 1,
                "value": 1.0,
                "interpolation": "hold",
            }],
        }],
    }


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    }:
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v26.")
    if document.get("schemaVersion") != 26 or not isinstance(document.get("scenes"), list):
        raise ValueError("La Biblioteca seleccionada no declara el contrato v26.")
    result = copy.deepcopy(document)
    for scene in result["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        identity = scene.get("id") if isinstance(scene, dict) else None
        if not isinstance(identity, str) or not isinstance(snapshot, dict) \
                or snapshot.get("schema") != "ScreenSimulation.SavedScene.v25" \
                or "animation" in snapshot:
            raise ValueError("Una escena v26 no contiene SavedScene v25 estricto.")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v26"
        snapshot["animation"] = animation_document(identity)
    result["schemaVersion"] = 27
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v26.json al contrato v27 actual.")
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
