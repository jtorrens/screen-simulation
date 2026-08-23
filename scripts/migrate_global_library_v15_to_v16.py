#!/usr/bin/env python3
"""One-way maintenance conversion adding the VFX delivery seeds to a selected v15 copy."""

import json
import pathlib
import sys

from migration_io import publish_with_source_backup


ROOT_KEYS = {
    "schemaVersion", "patterns", "testImages", "renderPresets", "wipReviewPresets",
    "devices", "coverGlasses", "cameras", "lenses", "environments",
}
PATTERN_ID = "screen-pattern-7"
PRESET_ID = "D7F465F6-3E58-4E8E-BEF3-A71A91E34C0A"


def migrate(source: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    document = json.loads(source.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 15 or set(document) != ROOT_KEYS:
        raise ValueError("source must be an unmodified Global Library v15")
    if any(item.get("value", {}).get("id") == PATTERN_ID for item in document["patterns"]):
        raise ValueError("v15 source already contains the v16 VFX stress pattern")
    if any(item.get("value", {}).get("id", "").upper() == PRESET_ID for item in document["renderPresets"]):
        raise ValueError("v15 source already contains the v16 VFX editorial preset")

    document["schemaVersion"] = 16
    document["patterns"].append({
        "value": {
            "id": PATTERN_ID,
            "name": "VFX Delivery Stress · ACEScg RGBA",
            "pattern": 7,
        },
        "isLocked": True,
    })
    document["renderPresets"].append({
        "value": {
            "id": PRESET_ID,
            "name": "VFX Editorial · ACEScct · ProRes 4444 XQ",
            "pipeline": "aces",
            "target": "vfxLog",
            "peakNits": 0,
            "format": "proRes4444XQ",
            "pixelEncoding": "rgb44412",
            "signalRange": "full",
            "alpha": "straight",
            "includeAudio": False,
            "notes": "Contrato editorial estándar: ACEScct/AP1, RGB Full Range, alfa straight lineal y sin ODT de display.",
        },
        "isLocked": True,
    })
    return publish_with_source_backup(source, destination, document)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: migrate_global_library_v15_to_v16.py SOURCE DESTINATION")
    backup = migrate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    print(f"backup: {backup}")
