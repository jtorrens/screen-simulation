#!/usr/bin/env python3
"""One-way selected maintenance migration from Autosave collection v25 to v26."""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import shutil
from pathlib import Path

from migrate_scene_library_v28_to_v29 import migrate_animation


def migrated_revision(source: Path) -> dict:
    revision = json.loads(source.read_text(encoding="utf-8"))
    snapshot = revision.get("snapshot") if isinstance(revision, dict) else None
    if not isinstance(revision, dict) \
            or revision.get("schema") != "ScreenSimulation.SceneAutosave.v3" \
            or not isinstance(snapshot, dict):
        raise ValueError("Una revisión v25 no contiene SceneAutosave v3 estricto.")
    result = copy.deepcopy(revision)
    result["schema"] = "ScreenSimulation.SceneAutosave.v4"
    migrate_animation(result["snapshot"])
    return result


def tree_bytes(root: Path) -> dict[str, bytes]:
    return {str(path.relative_to(root)): path.read_bytes()
            for path in root.rglob("*") if path.is_file()}


def migrate(source: Path, destination: Path) -> Path:
    if source.resolve() == destination.resolve():
        raise ValueError("La migración exige un destino nuevo y distinto.")
    if not source.is_dir() or destination.exists():
        raise ValueError("La migración exige una colección origen y un destino nuevo.")
    migrated = {path.relative_to(source): migrated_revision(path)
                for path in sorted(source.rglob("*.json"))}
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
    parser = argparse.ArgumentParser(description="Migra Autosave.v25 al contrato v26 actual.")
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
