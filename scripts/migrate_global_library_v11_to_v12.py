#!/usr/bin/env python3
"""One-way maintenance migration for an explicitly selected Global Library copy."""

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.destination.resolve():
        raise SystemExit("source and destination must differ")
    if args.destination.exists():
        raise SystemExit(f"destination already exists: {args.destination}")
    document = json.loads(args.source.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 11:
        raise SystemExit("source is not Global Library schema 11")
    for item in document.get("devices", []):
        value = item.get("value")
        if not isinstance(value, dict) or "cornerRadiusMeters" in value:
            raise SystemExit("invalid schema-11 Device record")
        value["cornerRadiusMeters"] = 0.0
    document["schemaVersion"] = 12
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    args.destination.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
