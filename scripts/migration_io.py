#!/usr/bin/env python3
"""Recoverable publication boundary shared by explicit maintenance migrations."""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import shutil
import tempfile
from typing import Any


def publish_with_source_backup(
    source: pathlib.Path,
    destination: pathlib.Path,
    document: dict[str, Any],
) -> pathlib.Path:
    if destination.exists():
        raise FileExistsError(f"migration destination already exists: {destination}")
    source_bytes = source.read_bytes()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = source.with_name(f"{source.stem}.backup-{stamp}{source.suffix}")
    if backup.exists():
        raise FileExistsError(f"migration backup already exists: {backup}")
    shutil.copy2(source, backup)
    if backup.read_bytes() != source_bytes:
        raise OSError("migration source backup verification failed")

    destination.parent.mkdir(parents=True, exist_ok=True)
    encoded = (
        json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    temporary: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=destination.parent,
            prefix=f".{destination.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = pathlib.Path(handle.name)
            os.fchmod(handle.fileno(), source.stat().st_mode & 0o777)
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except Exception:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise
    return backup
