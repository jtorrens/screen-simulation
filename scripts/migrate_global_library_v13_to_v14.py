#!/usr/bin/env python3
"""One-way selected maintenance migration from Global Library v13 to v14."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path


ROOT_KEYS = {
    "schemaVersion", "patterns", "testImages", "renderPresets", "devices",
    "coverGlasses", "cameras", "lenses", "environments",
}


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != ROOT_KEYS:
        fail("La Biblioteca Global seleccionada no tiene la forma estricta v13.")
    if document.get("schemaVersion") != 13:
        fail("La Biblioteca Global seleccionada no declara el contrato v13.")
    environments = document.get("environments")
    if not isinstance(environments, list) or not environments:
        fail("La Biblioteca Global v13 no contiene perfiles Environment explícitos.")
    for item in environments:
        if not isinstance(item, dict) or set(item) != {"value", "isLocked"}:
            fail("Un perfil Environment v13 no tiene la forma requerida.")
        value = item.get("value")
        environment = value.get("environment") if isinstance(value, dict) else None
        if not isinstance(environment, dict):
            fail("Un perfil Environment v13 no contiene parámetros físicos.")
        if "placementTangentTransform" in environment:
            fail("Un perfil v13 ya contiene el campo exclusivo de colocación v14.")
        try:
            scale = float(environment.pop("placementAngularScale"))
            roll = math.radians(float(environment.pop("placementRollDegrees")))
        except (KeyError, TypeError, ValueError) as error:
            fail("Un perfil Environment v13 no contiene escala y roll válidos.")
        if not math.isfinite(scale) or scale <= 0 or not math.isfinite(roll):
            fail("La colocación Environment v13 no es finita y positiva.")
        environment["placementTangentTransform"] = [
            math.cos(roll) / scale,
            math.sin(roll) / scale,
            0.0,
            0.0,
        ]
    document["schemaVersion"] = 14
    return document


def migrate(source: Path, destination: Path) -> None:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    document = migrated_document(source)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Migra GlobalLibrary.v13.json al contrato v14 actual."
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
