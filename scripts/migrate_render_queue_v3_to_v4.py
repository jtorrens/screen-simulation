#!/usr/bin/env python3
"""One-way maintenance conversion for an explicitly selected Render Queue copy."""

import json
import pathlib
import sys


def migrate(source: pathlib.Path, destination: pathlib.Path) -> None:
    document = json.loads(source.read_text(encoding="utf-8"))
    if document.get("schema") != "ScreenSimulation.RenderQueue.v3":
        raise ValueError("source must be ScreenSimulation.RenderQueue.v3")
    if set(document) != {"schema", "isPaused", "jobs"}:
        raise ValueError("unknown Render Queue fields")
    for job in document["jobs"]:
        if "derivedFromJobID" in job:
            raise ValueError("v3 job unexpectedly contains derivedFromJobID")
        job["derivedFromJobID"] = None
    document["schema"] = "ScreenSimulation.RenderQueue.v4"
    destination.write_text(
        json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: migrate_render_queue_v3_to_v4.py SOURCE DESTINATION")
    migrate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
