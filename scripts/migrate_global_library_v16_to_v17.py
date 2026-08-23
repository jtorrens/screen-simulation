#!/usr/bin/env python3
"""One-way maintenance conversion making VFX 2D DOF the default for every camera."""

import json
import pathlib
import sys

from migration_io import publish_with_source_backup


ROOT_KEYS = {
    "schemaVersion", "patterns", "testImages", "renderPresets", "wipReviewPresets",
    "devices", "coverGlasses", "cameras", "lenses", "environments",
}
DEFAULT_LENS_EVALUATION_MODEL_ID = "vfx-2d-dof"


def migrate(source: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    document = json.loads(source.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 16 or set(document) != ROOT_KEYS:
        raise ValueError("source must be an unmodified Global Library v16")
    cameras = document.get("cameras")
    if not isinstance(cameras, list) or not cameras:
        raise ValueError("v16 source must contain at least one camera")
    for item in cameras:
        if not isinstance(item, dict) or set(item) != {"value", "isLocked"}:
            raise ValueError("every v16 camera must be one strict library item")
        value = item.get("value")
        if not isinstance(value, dict) or "defaultLensEvaluationModelID" not in value:
            raise ValueError("every v16 camera must declare its default Lens evaluation model")
        value["defaultLensEvaluationModelID"] = DEFAULT_LENS_EVALUATION_MODEL_ID
    document["schemaVersion"] = 17
    return publish_with_source_backup(source, destination, document)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: migrate_global_library_v16_to_v17.py SOURCE DESTINATION")
    backup = migrate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    print(f"backup: {backup}")
