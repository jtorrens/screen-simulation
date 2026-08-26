#!/usr/bin/env python3
"""One-way selected maintenance normalization for associated v24 names."""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import os
import shutil
import uuid
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def required_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{field} necesita texto no vacío.")
    return value


def normalized_document(source: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    }:
        fail("La Biblioteca seleccionada no tiene la forma estricta v24.")
    if document.get("schemaVersion") != 24:
        fail("La Biblioteca seleccionada no declara el contrato v24.")
    if not isinstance(document["scenes"], list) or not isinstance(document["productions"], list):
        fail("Las colecciones de la Biblioteca v24 no son válidas.")
    if not isinstance(document["unclassifiedSceneIDs"], list):
        fail("La colección Sin clasificar no es válida.")

    result = copy.deepcopy(document)
    scene_indexes: dict[str, int] = {}
    for index, scene in enumerate(result["scenes"]):
        if not isinstance(scene, dict):
            fail("Una Escena v24 no es un objeto.")
        scene_id = required_string(scene.get("id"), "scene.id")
        try:
            uuid.UUID(scene_id)
        except ValueError:
            fail("Una Escena v24 no contiene un UUID válido.")
        if scene_id in scene_indexes:
            fail("La Biblioteca v24 contiene identidades de Escena duplicadas.")
        scene_indexes[scene_id] = index

    placements: list[str] = []
    for production in result["productions"]:
        if not isinstance(production, dict) or not isinstance(production.get("episodes"), list):
            fail("Una Producción v24 no contiene Episodios válidos.")
        for episode in production["episodes"]:
            if not isinstance(episode, dict) or not isinstance(episode.get("shots"), list):
                fail("Un Episodio v24 no contiene Planos válidos.")
            if episode.get("associationState") == "associated":
                reference = episode.get("externalReference")
                if not isinstance(reference, dict):
                    fail("Un Episodio asociado no contiene referencia externa.")
                episode["name"] = required_string(
                    reference.get("episodeSlug"), "externalReference.episodeSlug"
                )
            for shot in episode["shots"]:
                if not isinstance(shot, dict) or not isinstance(shot.get("scenes"), list):
                    fail("Un Plano v24 no contiene colocaciones válidas.")
                if shot.get("associationState") == "associated":
                    reference = shot.get("externalReference")
                    if not isinstance(reference, dict):
                        fail("Un Plano asociado no contiene referencia externa.")
                    shot["name"] = required_string(
                        reference.get("canonicalName"), "externalReference.canonicalName"
                    )
                shot_name = required_string(shot.get("name"), "shot.name")
                for placement in shot["scenes"]:
                    if not isinstance(placement, dict):
                        fail("Una colocación de Escena no es válida.")
                    scene_id = required_string(placement.get("sceneID"), "placement.sceneID")
                    ordinal = placement.get("ordinal")
                    if scene_id not in scene_indexes or not isinstance(ordinal, int) or not 1 <= ordinal <= 999:
                        fail("Una colocación de Escena no contiene identidad u ordinal válido.")
                    placements.append(scene_id)
                    result["scenes"][scene_indexes[scene_id]]["name"] = f"{shot_name}_{ordinal:03d}"

    unclassified = result["unclassifiedSceneIDs"]
    if not all(isinstance(scene_id, str) and scene_id in scene_indexes for scene_id in unclassified):
        fail("Sin clasificar contiene una identidad de Escena desconocida.")
    all_members = placements + unclassified
    if len(all_members) != len(set(all_members)) or set(all_members) != set(scene_indexes):
        fail("Cada Escena debe aparecer exactamente una vez en el árbol.")
    return result


def migrate(source: Path) -> Path:
    result = normalized_document(source)
    source_bytes = source.read_bytes()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = source.with_name(f"{source.name}.backup-associated-names-{stamp}")
    if backup.exists():
        fail(f"La copia de seguridad ya existe: {backup}")
    shutil.copyfile(source, backup)
    if backup.read_bytes() != source_bytes:
        backup.unlink(missing_ok=True)
        fail("La copia de seguridad no es byte-identical.")
    temporary = source.with_name(f".{source.name}.associated-names-{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, source)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return backup


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Normaliza nombres asociados de una Biblioteca Scenes.v24.json seleccionada."
    )
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        backup = migrate(args.source.resolve())
        print(f"Copia verificada: {backup}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
