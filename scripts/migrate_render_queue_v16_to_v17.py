#!/usr/bin/env python3
"""One-way selected maintenance migration from Render Queue v16 to v17."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migrate_scene_library_v29_to_v30 import migrate_simulation_model
from migration_io import publish_with_source_backup


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) \
            or set(document) != {"schema", "isPaused", "jobs"} \
            or document.get("schema") != "ScreenSimulation.RenderQueue.v16" \
            or not isinstance(document.get("jobs"), list):
        raise ValueError("La cola seleccionada no tiene la forma estricta v16.")
    result = copy.deepcopy(document)
    for job in result["jobs"]:
        scene = job.get("scene") if isinstance(job, dict) else None
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        if not isinstance(snapshot, dict):
            raise ValueError("Un trabajo v16 no contiene una escena estricta.")
        migrate_simulation_model(snapshot)
    result["schema"] = "ScreenSimulation.RenderQueue.v17"
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra RenderQueue.v16.json al contrato v17 actual.")
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
