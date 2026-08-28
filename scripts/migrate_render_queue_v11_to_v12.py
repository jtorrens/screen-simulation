#!/usr/bin/env python3
"""One-way selected maintenance migration from Render Queue v11 to v12."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("schema") != "ScreenSimulation.RenderQueue.v11":
        raise ValueError("La cola seleccionada no declara RenderQueue v11.")
    if set(document) != {"schema", "isPaused", "jobs"} or not isinstance(document["jobs"], list):
        raise ValueError("La cola seleccionada no tiene la forma estricta v11.")
    result = copy.deepcopy(document)
    for job in result["jobs"]:
        snapshot = job.get("scene", {}).get("snapshot") if isinstance(job, dict) else None
        if not isinstance(snapshot, dict) \
                or snapshot.get("schema") != "ScreenSimulation.SavedScene.v24" \
                or "trackingSceneMethod" in snapshot \
                or "fusionTrackerMotion" not in snapshot:
            raise ValueError("Un trabajo v11 no contiene SavedScene v24 estricto.")
        snapshot["schema"] = "ScreenSimulation.SavedScene.v25"
        snapshot["trackingSceneMethod"] = (
            "fusionTrackerClipboard"
            if snapshot["fusionTrackerMotion"] is not None
            else "fusionComposition"
        )
    result["schema"] = "ScreenSimulation.RenderQueue.v12"
    return result


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    return publish_with_source_backup(source, destination, migrated_document(source))


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra RenderQueue.v11.json al contrato v12 actual.")
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
