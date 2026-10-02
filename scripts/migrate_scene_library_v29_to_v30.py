#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v29 to v30."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrate_simulation_model(snapshot: dict) -> None:
    authoring = snapshot.get("authoring")
    if snapshot.get("schema") != "ScreenSimulation.SavedScene.v27" \
            or not isinstance(authoring, dict) \
            or authoring.get("schema") != "ScreenSimulation.SceneAuthoring.v4" \
            or "activeModel" in authoring \
            or "vfxContinuity" in authoring:
        raise ValueError(
            "Una escena v29 no contiene SavedScene v27 y SceneAuthoring v4 estrictos."
        )
    snapshot["schema"] = "ScreenSimulation.SavedScene.v28"
    authoring["schema"] = "ScreenSimulation.SceneAuthoring.v5"
    authoring["activeModel"] = "physical"
    authoring["vfxContinuity"] = {
        "relativePanelLevel": 1.0,
    }


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    } or document.get("schemaVersion") != 29 \
            or not isinstance(document.get("scenes"), list):
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v29.")
    result = copy.deepcopy(document)
    for scene in result["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        if not isinstance(snapshot, dict):
            raise ValueError("Una escena v29 no contiene un snapshot estricto.")
        migrate_simulation_model(snapshot)
    result["schemaVersion"] = 30
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v29.json al contrato v30 actual.")
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
