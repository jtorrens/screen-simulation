#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v31 to v32."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrate_scene_duration(snapshot: dict) -> None:
    if snapshot.get("schema") != "ScreenSimulation.SavedScene.v29" or "durationFrames" in snapshot:
        raise ValueError("La escena requiere el contrato SavedScene v29 sin duración explícita.")
    snapshot["schema"] = "ScreenSimulation.SavedScene.v30"
    snapshot["durationFrames"] = None


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    } or document.get("schemaVersion") != 31 \
            or not isinstance(document.get("scenes"), list):
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v31.")
    result = copy.deepcopy(document)
    for scene in result["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        if not isinstance(snapshot, dict):
            raise ValueError("Una escena v31 no contiene un snapshot estricto.")
        migrate_scene_duration(snapshot)
    result["schemaVersion"] = 32
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v31.json al contrato v32 actual.")
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
