#!/usr/bin/env python3
"""One-way selected maintenance migration from Autosave collection v24 to v25."""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import shutil
from pathlib import Path

from migrate_scene_library_v26_to_v27 import animation_document


def migrated_revision(source: Path) -> dict:
    revision = json.loads(source.read_text(encoding="utf-8"))
    snapshot = revision.get("snapshot") if isinstance(revision, dict) else None
    identity = revision.get("originalSceneID") if isinstance(revision, dict) else None
    if not isinstance(revision, dict) \
            or revision.get("schema") != "ScreenSimulation.SceneAutosave.v2" \
            or not isinstance(identity, str) or not isinstance(snapshot, dict) \
            or snapshot.get("schema") != "ScreenSimulation.SavedScene.v25" \
            or "animation" in snapshot:
        raise ValueError("Una revisión v24 no contiene SceneAutosave v2 y SavedScene v25 estrictos.")
    result = copy.deepcopy(revision)
    result["schema"] = "ScreenSimulation.SceneAutosave.v3"
    result["snapshot"]["schema"] = "ScreenSimulation.SavedScene.v26"
    result["snapshot"]["animation"] = animation_document(identity)
    return result


def tree_bytes(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in root.rglob("*") if path.is_file()
    }


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    if not source.is_dir():
        raise ValueError("La colección Autosave.v24 seleccionada no existe.")
    if destination.exists():
        raise FileExistsError(f"migration destination already exists: {destination}")
    revisions = sorted(source.rglob("*.json"))
    migrated = {path.relative_to(source): migrated_revision(path) for path in revisions}
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = source.with_name(f"{source.name}.backup-{stamp}")
    shutil.copytree(source, backup, copy_function=shutil.copy2)
    if tree_bytes(backup) != tree_bytes(source):
        raise OSError("migration source backup verification failed")
    temporary = destination.with_name(f".{destination.name}.migrating-{stamp}")
    try:
        shutil.copytree(source, temporary, copy_function=shutil.copy2)
        for relative, document in migrated.items():
            (temporary / relative).write_text(
                json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        temporary.rename(destination)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return backup


def main() -> None:
    parser = argparse.ArgumentParser(description="Migra Autosave.v24 al contrato v25 actual.")
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
