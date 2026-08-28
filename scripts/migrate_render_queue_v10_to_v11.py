#!/usr/bin/env python3
"""One-way selected maintenance migration from Render Queue v10 to v11."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("schema") != "ScreenSimulation.RenderQueue.v10":
        raise ValueError("La cola seleccionada no declara RenderQueue v10.")
    if set(document) != {"schema", "isPaused", "jobs"} or not isinstance(document["jobs"], list):
        raise ValueError("La cola seleccionada no tiene la forma estricta v10.")
    result = copy.deepcopy(document)
    for job in result["jobs"]:
        if not isinstance(job, dict) or not isinstance(job.get("scene"), dict):
            raise ValueError("Un trabajo v10 no contiene su Saved Scene.")
        saved_scene = job["scene"]
        snapshot = saved_scene.get("snapshot")
        if not isinstance(snapshot, dict):
            raise ValueError("Un trabajo v10 no contiene snapshot.")
        if snapshot.get("schema") != "ScreenSimulation.SavedScene.v23" or "fusionTrackerMotion" in snapshot:
            raise ValueError("Un trabajo v10 no contiene SavedScene v23 estricto.")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v24"
        snapshot["fusionTrackerMotion"] = None
    result["schema"] = "ScreenSimulation.RenderQueue.v11"
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra RenderQueue.v10.json al contrato v11 actual.")
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
