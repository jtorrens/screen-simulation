#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v28 to v29."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrate_animation(snapshot: dict) -> None:
    animation = snapshot.get("animation")
    if snapshot.get("schema") != "ScreenSimulation.SavedScene.v26" \
            or not isinstance(animation, dict) \
            or set(animation) != {"schema", "scalarTracks"} \
            or animation.get("schema") != "ScreenSimulation.SceneAnimation.v1" \
            or not isinstance(animation.get("scalarTracks"), list):
        raise ValueError("Una escena v28 no contiene SavedScene v26 y SceneAnimation v1 estrictos.")
    snapshot["schema"] = "ScreenSimulation.SavedScene.v27"
    animation["schema"] = "ScreenSimulation.SceneAnimation.v2"
    animation["transformTracks"] = []


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    } or document.get("schemaVersion") != 28 \
            or not isinstance(document.get("scenes"), list):
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v28.")
    result = copy.deepcopy(document)
    for scene in result["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        if not isinstance(snapshot, dict):
            raise ValueError("Una escena v28 no contiene un snapshot estricto.")
        migrate_animation(snapshot)
    result["schemaVersion"] = 29
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v28.json al contrato v29 actual.")
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
