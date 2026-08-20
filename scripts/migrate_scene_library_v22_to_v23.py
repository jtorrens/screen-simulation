#!/usr/bin/env python3
"""One-way selected maintenance migration from workstation Scene Library v22 to v23."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def migrated_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {"schemaVersion", "scenes"}:
        fail("La Biblioteca de Escenas seleccionada no tiene la forma estricta v22.")
    if document.get("schemaVersion") != 22 or not isinstance(document.get("scenes"), list):
        fail("La Biblioteca de Escenas seleccionada no declara el contrato v22.")
    for scene in document["scenes"]:
        snapshot = scene.get("snapshot") if isinstance(scene, dict) else None
        authoring = snapshot.get("authoring") if isinstance(snapshot, dict) else None
        context = authoring.get("context") if isinstance(authoring, dict) else None
        if not isinstance(snapshot, dict) or snapshot.get("schema") != "ScreenSimulation.SavedScene.v22":
            fail("Una escena no declara el contrato SavedScene v22.")
        if not isinstance(authoring, dict) or authoring.get("schema") != "ScreenSimulation.SceneAuthoring.v3":
            fail("Una escena no declara el contrato de autoría v3.")
        if not isinstance(context, dict) or "referencePlateID" in context:
            fail("Una escena v22 no contiene el contexto de referencia esperado.")
        reference = context.get("referenceResource")
        if not isinstance(reference, dict):
            fail("Una escena v22 no contiene el recurso de referencia.")
        context["referencePlateID"] = (
            "video-reference" if reference.get("kind") == "imageOrVideo" else "vfx-checker"
        )
        authoring["schema"] = "ScreenSimulation.SceneAuthoring.v4"
        snapshot["schema"] = "ScreenSimulation.SavedScene.v23"
    document["schemaVersion"] = 23
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
    parser = argparse.ArgumentParser(description="Migra Scenes.v22.json al contrato v23 actual.")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        migrate(args.source.resolve(), args.destination.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
