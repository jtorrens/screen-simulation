#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v30 to v31."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrate_vfx_optical_character(snapshot: dict) -> None:
    authoring = snapshot.get("authoring")
    vfx = authoring.get("vfxContinuity") if isinstance(authoring, dict) else None
    if snapshot.get("schema") != "ScreenSimulation.SavedScene.v28" \
            or not isinstance(authoring, dict) \
            or authoring.get("schema") != "ScreenSimulation.SceneAuthoring.v5" \
            or not isinstance(vfx, dict) \
            or set(vfx) != {"relativePanelLevel"}:
        raise ValueError(
            "Una escena v30 no contiene SavedScene v28, SceneAuthoring v5 "
            "y el estado VFX estricto esperado."
        )
    snapshot["schema"] = "ScreenSimulation.SavedScene.v29"
    authoring["schema"] = "ScreenSimulation.SceneAuthoring.v6"
    vfx["emissionPresence"] = 1.0
    vfx["chromaticFringe"] = 1.0


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    } or document.get("schemaVersion") != 30 \
            or not isinstance(document.get("scenes"), list):
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v30.")
    result = copy.deepcopy(document)
    for scene in result["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        if not isinstance(snapshot, dict):
            raise ValueError("Una escena v30 no contiene un snapshot estricto.")
        migrate_vfx_optical_character(snapshot)
    result["schemaVersion"] = 31
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v30.json al contrato v31 actual.")
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
