#!/usr/bin/env python3
"""One-way selected maintenance migration from global library v9 to v10."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


ROOT_KEYS = {"schemaVersion", "patterns", "testImages", "renderPresets", "devices", "coverGlasses"}
OLD_KEYS = {
    "glowScatterFraction", "glowCoreRadiusMillimeters",
    "glowTailRadiusMillimeters", "glowTailFraction",
}


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS or document.get("schemaVersion") != 9:
        fail("La biblioteca global seleccionada no declara la forma estricta v9.")
    covers = document.get("coverGlasses")
    if not isinstance(covers, list):
        fail("La biblioteca global v9 no contiene Cover Glasses explícitos.")
    for item in covers:
        if not isinstance(item, dict) or set(item) != {"value", "isLocked"}:
            fail("Un Cover Glass global v9 no tiene la forma requerida.")
        cover = item.get("value")
        if not isinstance(cover, dict) or not OLD_KEYS.issubset(cover):
            fail("Un Cover Glass global v9 no contiene el Glow completo.")
        if "glowIntensity" in cover or "glowRadiusMillimeters" in cover:
            fail("Un Cover Glass global v9 ya contiene campos exclusivos de v10.")
        cover["glowIntensity"] = cover["glowScatterFraction"]
        cover["glowRadiusMillimeters"] = cover["glowTailRadiusMillimeters"]
        for key in OLD_KEYS:
            del cover[key]
    document["schemaVersion"] = 10
    return document


def migrate(source: Path, destination: Path) -> None:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    document = migrated_document(source)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra GlobalLibrary v9 al contrato v10 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
