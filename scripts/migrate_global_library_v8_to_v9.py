#!/usr/bin/env python3
"""One-way selected maintenance migration from global library v8 to v9."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from migrate_scene_library_v12_to_v13 import BUILTIN_THRESHOLDS, fail


ROOT_KEYS = {"schemaVersion", "patterns", "testImages", "renderPresets", "devices", "coverGlasses"}


def migrated_document(source: Path, explicit_thresholds: dict[str, float] | None = None) -> dict:
    thresholds = {**BUILTIN_THRESHOLDS, **(explicit_thresholds or {})}
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS or document.get("schemaVersion") != 8:
        fail("La biblioteca global seleccionada no declara la forma estricta v8.")
    covers = document.get("coverGlasses")
    if not isinstance(covers, list):
        fail("La biblioteca global v8 no contiene Cover Glasses explícitos.")
    for item in covers:
        if not isinstance(item, dict) or set(item) != {"value", "isLocked"}:
            fail("Un Cover Glass global v8 no tiene la forma requerida.")
        cover = item.get("value")
        identity = cover.get("id") if isinstance(cover, dict) else None
        if not isinstance(identity, str) or identity not in thresholds:
            fail(f"Falta un umbral explícito para el Cover Glass {identity!r}.")
        if "glowThresholdRelativeWhite" in cover:
            fail("Un Cover Glass v8 ya contiene el campo exclusivo de v9.")
        threshold = thresholds[identity]
        if not isinstance(threshold, (int, float)) or not 0.0 <= float(threshold) <= 1.0:
            fail(f"El umbral explícito de {identity!r} no es válido.")
        cover["glowThresholdRelativeWhite"] = float(threshold)
    document["schemaVersion"] = 9
    return document


def migrate(source: Path, destination: Path, explicit_thresholds: dict[str, float] | None = None) -> None:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    document = migrated_document(source, explicit_thresholds)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra GlobalLibrary v8 al contrato v9 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--threshold", action="append", default=[], metavar="COVER_ID=VALUE")
    args = parser.parse_args()
    explicit: dict[str, float] = {}
    try:
        for entry in args.threshold:
            identity, value = entry.rsplit("=", 1)
            explicit[identity] = float(value)
        migrate(args.source.resolve(), args.destination.resolve(), explicit)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
