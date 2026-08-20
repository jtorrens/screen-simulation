#!/usr/bin/env python3
"""One-way selected maintenance migration from workstation Scene Library v21 to v22."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path


OLD_IDS = {
    "environment-tangent-m00",
    "environment-tangent-m01",
    "environment-tangent-m10",
    "environment-tangent-m11",
}
NEW_IDS = (
    "environment-mobius-a-real",
    "environment-mobius-a-imag",
    "environment-mobius-c-real",
    "environment-mobius-c-imag",
)


def fail(message: str) -> None:
    raise ValueError(message)


def migrate_overrides(overrides: list[dict]) -> None:
    old = {item.get("controlID"): item for item in overrides if item.get("controlID") in OLD_IDS}
    if not old:
        return
    if set(old) != OLD_IDS or any(item.get("kind") != "scalar" for item in old.values()):
        fail("La escena contiene una transformación tangente v21 incompleta.")
    values = {key: float(item["scalar"]) for key, item in old.items()}
    m00 = values["environment-tangent-m00"]
    m01 = values["environment-tangent-m01"]
    m10 = values["environment-tangent-m10"]
    m11 = values["environment-tangent-m11"]
    if not all(math.isfinite(value) for value in values.values()):
        fail("La escena contiene una transformación tangente v21 no finita.")
    if abs(m01 + m10) > 1.0e-5 or abs(m11 - m00) > 1.0e-5:
        fail("La transformación tangente v21 no tiene un equivalente Möbius exacto.")
    overrides[:] = [item for item in overrides if item.get("controlID") not in OLD_IDS]
    for control_id, value in zip(NEW_IDS, (m00, m10, 0.0, 0.0)):
        overrides.append({"controlID": control_id, "kind": "scalar", "scalar": value})


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "scenes"}:
        fail("La Biblioteca de Escenas seleccionada no tiene la forma estricta v21.")
    if document.get("schemaVersion") != 21 or not isinstance(document.get("scenes"), list):
        fail("La Biblioteca de Escenas seleccionada no declara el contrato v21.")
    for scene in document["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        authoring = snapshot.get("authoring") if isinstance(snapshot, dict) else None
        overrides = authoring.get("overrides") if isinstance(authoring, dict) else None
        if snapshot is None or snapshot.get("schema") != "ScreenSimulation.SavedScene.v21":
            fail("Una escena no declara el contrato SavedScene v21.")
        if not isinstance(overrides, list):
            fail("Una escena v21 no contiene overrides tipados.")
        migrate_overrides(overrides)
        snapshot["schema"] = "ScreenSimulation.SavedScene.v22"
    document["schemaVersion"] = 22
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
    parser = argparse.ArgumentParser(description="Migra Scenes.v21.json al contrato v22 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
