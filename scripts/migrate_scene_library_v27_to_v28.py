#!/usr/bin/env python3
"""One-way selected maintenance migration from Scene Library v27 to v28."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from migration_io import publish_with_source_backup


def require_safe_segment(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or value in {".", ".."} \
            or "/" in value or "\\" in value or "\0" in value:
        raise ValueError(f"{field} no es un segmento seguro.")
    return value


def episode_paths(production_jsons: list[Path]) -> dict[tuple[str, str], list[str]]:
    result: dict[tuple[str, str], list[str]] = {}
    for source in production_jsons:
        if source.name != "production.json":
            raise ValueError(f"El catálogo debe llamarse exactamente production.json: {source}")
        document = json.loads(source.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise ValueError(f"production.json no contiene un objeto: {source}")
        production_id = document.get("productionId")
        episodes = document.get("episodes")
        if not isinstance(production_id, str) or not production_id \
                or not isinstance(episodes, list):
            raise ValueError(
                f"production.json no publica productionId y episodes legibles: {source}"
            )
        for episode in episodes:
            if not isinstance(episode, dict) or not isinstance(episode.get("id"), str):
                raise ValueError(f"production.json contiene un Episodio sin id: {source}")
            path_segments = episode.get("pathSegments")
            if not isinstance(path_segments, list) or not path_segments:
                raise ValueError(
                    f"El Episodio {episode['id']} no publica pathSegments: {source}"
                )
            canonical = [
                require_safe_segment(segment, "episode.pathSegments")
                for segment in path_segments
            ]
            key = (production_id, episode["id"])
            if key in result:
                raise ValueError(
                    f"La ruta de Producción/Episodio está duplicada: {production_id}/{episode['id']}"
                )
            result[key] = canonical
    return result


def migrated_document(source: Path, production_jsons: list[Path]) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or set(document) != {
        "schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"
    }:
        raise ValueError("La Biblioteca seleccionada no tiene la forma estricta v27.")
    if document.get("schemaVersion") != 27 \
            or not isinstance(document.get("scenes"), list) \
            or not isinstance(document.get("productions"), list) \
            or not isinstance(document.get("unclassifiedSceneIDs"), list):
        raise ValueError("La Biblioteca seleccionada no declara el contrato v27.")

    paths = episode_paths(production_jsons)
    result = copy.deepcopy(document)
    for production in result["productions"]:
        if not isinstance(production, dict) or not isinstance(production.get("episodes"), list):
            raise ValueError("Una Producción v27 no contiene Episodios válidos.")
        for episode in production["episodes"]:
            if not isinstance(episode, dict):
                raise ValueError("Una Producción v27 contiene un Episodio no válido.")
            reference = episode.get("externalReference")
            if reference is None:
                continue
            if not isinstance(reference, dict) or set(reference) != {
                "productionId", "episodeId", "episodeOrder", "episodeSlug"
            }:
                raise ValueError("Una referencia externa de Episodio no tiene la forma estricta v27.")
            key = (reference.get("productionId"), reference.get("episodeId"))
            if key not in paths:
                raise ValueError(
                    "No existe pathSegments autoritativo para la referencia "
                    f"{reference.get('productionId')}/{reference.get('episodeId')}."
                )
            reference["episodePathSegments"] = paths[key]

    result["schemaVersion"] = 28
    return result


def migrate(source: Path, destination: Path, production_jsons: list[Path]) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    result = migrated_document(source, production_jsons)
    return publish_with_source_backup(source, destination, result)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Migra Scenes.v27.json al contrato v28 actual."
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument(
        "production_json", type=Path, nargs="*",
        help="production.json legible para cada Producción/Episodio referenciado",
    )
    args = parser.parse_args()
    try:
        backup = migrate(
            args.source.resolve(), args.destination.resolve(),
            [path.resolve() for path in args.production_json],
        )
        print(f"Copia verificada: {backup}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
