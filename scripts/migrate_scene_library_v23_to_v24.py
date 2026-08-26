#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v23 to v24."""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import uuid
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "scenes"}:
        fail("La Biblioteca seleccionada no tiene la forma estricta v23.")
    scenes = document.get("scenes")
    if document.get("schemaVersion") != 23 or not isinstance(scenes, list):
        fail("La Biblioteca seleccionada no declara el contrato v23.")
    ids: list[str] = []
    for scene in scenes:
        if not isinstance(scene, dict) or not isinstance(scene.get("id"), str):
            fail("Una escena v23 no contiene una identidad válida.")
        try:
            uuid.UUID(scene["id"])
        except ValueError:
            fail("Una escena v23 no contiene un UUID válido.")
        snapshot = scene.get("snapshot")
        if not isinstance(snapshot, dict) or snapshot.get("schema") != "ScreenSimulation.SavedScene.v23":
            fail("Una escena no declara SavedScene v23.")
        ids.append(scene["id"])
    if len(set(ids)) != len(ids):
        fail("La Biblioteca v23 contiene identidades duplicadas.")
    return {
        "schemaVersion": 24,
        "scenes": scenes,
        "productions": [],
        "unclassifiedSceneIDs": ids,
    }


def migrate(source: Path, destination: Path) -> Path:
    if source == destination:
        fail("La migración exige un destino nuevo y distinto.")
    if destination.exists():
        fail(f"El destino ya existe: {destination}")
    result = migrated_document(source)
    source_bytes = source.read_bytes()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = source.with_name(f"{source.name}.backup-{stamp}")
    if backup.exists():
        fail(f"La copia de seguridad ya existe: {backup}")
    shutil.copyfile(source, backup)
    if backup.read_bytes() != source_bytes:
        backup.unlink(missing_ok=True)
        fail("La copia de seguridad no es byte-identical.")
    temporary = destination.with_name(destination.name + ".tmp")
    try:
        temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return backup


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Scenes.v23.json al contrato v24 actual.")
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
