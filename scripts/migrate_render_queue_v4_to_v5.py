#!/usr/bin/env python3
"""One-way maintenance conversion for an explicitly selected Render Queue copy."""

import json
import pathlib
import sys

from migration_io import publish_with_source_backup


def migrate(source: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {"schema", "isPaused", "jobs"}:
        raise ValueError("unknown Render Queue fields")
    if document.get("schema") != "ScreenSimulation.RenderQueue.v4":
        raise ValueError("source must be ScreenSimulation.RenderQueue.v4")
    if not isinstance(document.get("jobs"), list):
        raise ValueError("Render Queue jobs must be an array")
    for job in document["jobs"]:
        if not isinstance(job, dict) or not isinstance(job.get("configuration"), dict):
            raise ValueError("Render Queue job configuration is required")
        configuration = job["configuration"]
        if "alpha" not in configuration:
            raise ValueError("Render Queue output alpha is required")
        if configuration.get("wipReview") is not None:
            configuration["alpha"] = "ignore"
    document["schema"] = "ScreenSimulation.RenderQueue.v5"
    return publish_with_source_backup(source, destination, document)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: migrate_render_queue_v4_to_v5.py SOURCE DESTINATION")
    backup = migrate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    print(f"backup: {backup}")
