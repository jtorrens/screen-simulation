#!/usr/bin/env python3
"""One-way maintenance conversion for an explicitly selected Global Library copy."""

import json
import pathlib
import sys

from migration_io import publish_with_source_backup


POSITIONS = ["topLeft", "topCenter", "topRight", "bottomLeft", "bottomCenter", "bottomRight"]


def color(red: float, green: float, blue: float, alpha: float = 1.0) -> dict:
    return {"red": red, "green": green, "blue": blue, "alpha": alpha}


def zones() -> list[dict]:
    fields = {"topLeft": "outputFilename", "topRight": "frame", "bottomLeft": "date", "bottomRight": "timecode"}
    prefixes = {"topRight": "Frame "}
    return [{
        "position": position, "enabled": position in fields,
        "prefix": prefixes.get(position, ""), "calculatedField": fields.get(position, "none"),
        "offsetX": 0, "offsetY": 0,
        "fontSize": {"enabled": False, "value": 0},
        "color": {"enabled": False, "value": color(1, 1, 1)},
        "opacity": {"enabled": False, "value": 0},
    } for position in POSITIONS]


def preset(identifier: str, name: str, space: str, blanking: bool = False) -> dict:
    return {
        "id": identifier, "name": name, "outputColorSpace": space,
        "reviewRaster": "output", "placement": "fit", "resampleFilter": "lanczos",
        "canvasColor": color(0, 0, 0), "blankingEnabled": blanking,
        "blankingAspect": "ratio239", "blankingColor": color(0, 0, 0), "blankingOpacity": 1,
        "fontFamily": "Helvetica Neue", "fontStyle": "regular", "fontSize": 0.028,
        "textColor": color(1, 1, 1), "textOpacity": 1,
        "graphicsWhiteMode": "automatic", "graphicsWhiteNits": 203, "hlgPeakNits": 1000,
        "outlineEnabled": True, "outlineWidth": 0.001, "outlineColor": color(0, 0, 0), "outlineOpacity": 1,
        "shadowEnabled": False, "shadowOffsetX": 0.0015, "shadowOffsetY": 0.002, "shadowSoftness": 0.002,
        "shadowColor": color(0, 0, 0), "shadowOpacity": 0.60,
        "paddingLeft": 0.015, "paddingRight": 0.015, "paddingTop": 0.020, "paddingBottom": 0.020,
        "frameRelativeBase": 1, "frameStart": 1001, "frameRateMode": "render",
        "frameRateOverride": 24, "timecodeStart": "00:00:00:00", "reviewDate": "", "zones": zones(),
    }


def migrate(source: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    document = json.loads(source.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 14 or "wipReviewPresets" in document:
        raise ValueError("source must be an unmodified Global Library v14")
    seeds = [
        preset("913B66F2-3CAA-40D5-B123-82BE4BDF0101", "Editorial · Rec.709", "rec709Gamma24"),
        preset("913B66F2-3CAA-40D5-B123-82BE4BDF0102", "Editorial 2.39 · Rec.709", "rec709Gamma24", True),
        preset("913B66F2-3CAA-40D5-B123-82BE4BDF0103", "Editorial · Rec.2100 PQ", "rec2100PQ"),
        preset("913B66F2-3CAA-40D5-B123-82BE4BDF0104", "Editorial · Rec.2100 HLG", "rec2100HLG"),
    ]
    document["schemaVersion"] = 15
    document["wipReviewPresets"] = [{"value": value, "isLocked": True} for value in seeds]
    return publish_with_source_backup(source, destination, document)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: migrate_global_library_v14_to_v15.py SOURCE DESTINATION")
    backup = migrate(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    print(f"backup: {backup}")
