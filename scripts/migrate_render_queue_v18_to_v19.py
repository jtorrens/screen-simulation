#!/usr/bin/env python3
"""One-way selected maintenance migration from Render Queue v18 to v19."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migrate_scene_library_v31_to_v32 import migrate_scene_duration
from migration_io import publish_with_source_backup


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) \
            or set(document) != {"schema", "isPaused", "jobs"} \
            or document.get("schema") != "ScreenSimulation.RenderQueue.v18" \
            or not isinstance(document.get("jobs"), list):
        raise ValueError("La cola seleccionada no tiene la forma estricta v18.")
    result = copy.deepcopy(document)
    for job in result["jobs"]:
        scene = job.get("scene") if isinstance(job, dict) else None
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        if not isinstance(snapshot, dict):
            raise ValueError("Un trabajo v18 no contiene una escena estricta.")
        migrate_scene_duration(snapshot)
    result["schema"] = "ScreenSimulation.RenderQueue.v19"
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra RenderQueue.v18.json al contrato v19 actual.")
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
