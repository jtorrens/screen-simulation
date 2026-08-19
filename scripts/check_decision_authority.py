#!/usr/bin/env python3
"""Validate the single-owner index for active architecture decisions."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


OWNER = re.compile(r"<!--\s*decision-owner:\s*([a-z0-9][a-z0-9.-]*)\s*-->")
REFERENCE = re.compile(r"<!--\s*decision-ref:\s*([a-z0-9][a-z0-9.-]*)\s*-->")
DECISION_ID = re.compile(r"^[a-z0-9][a-z0-9.-]*$")


class DecisionAuthorityError(RuntimeError):
    pass


def _load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DecisionAuthorityError(f"Cannot load {path}: {error}") from error
    if not isinstance(value, dict):
        raise DecisionAuthorityError(f"{path} must contain one JSON object")
    return value


def _active_documents(root: Path) -> set[str]:
    readme = root / "Docs/architecture/README.md"
    try:
        text = readme.read_text(encoding="utf-8")
    except OSError as error:
        raise DecisionAuthorityError(f"Cannot read active architecture index: {error}") from error
    return {
        f"Docs/architecture/{name}"
        for name in re.findall(r"^- `([^`]+\.md)`:", text, flags=re.MULTILINE)
    }


def validate(root: Path) -> None:
    manifest_path = root / "architecture/decision-authority.json"
    manifest = _load_object(manifest_path)
    if set(manifest) != {"schema", "version", "decisions"}:
        raise DecisionAuthorityError("decision-authority.json has undeclared root fields")
    if manifest["schema"] != "screen_simulation_decision_authority" or manifest["version"] != 1:
        raise DecisionAuthorityError("decision-authority.json has an unknown contract")
    decisions = manifest["decisions"]
    if not isinstance(decisions, list) or not decisions:
        raise DecisionAuthorityError("decision-authority.json must declare decisions")

    active_documents = _active_documents(root)
    known: dict[str, dict[str, Any]] = {}
    for decision in decisions:
        if not isinstance(decision, dict) or set(decision) != {
            "id", "scope", "owner", "enforcement"
        }:
            raise DecisionAuthorityError("A decision has undeclared fields")
        decision_id = decision["id"]
        if not isinstance(decision_id, str) or not DECISION_ID.fullmatch(decision_id):
            raise DecisionAuthorityError(f"Invalid decision id: {decision_id!r}")
        if decision_id in known:
            raise DecisionAuthorityError(f"Duplicate decision id: {decision_id}")
        if not isinstance(decision["scope"], str) or not decision["scope"].strip():
            raise DecisionAuthorityError(f"Decision {decision_id} has no bounded scope")
        owner = decision["owner"]
        if not isinstance(owner, dict) or set(owner) != {"path", "anchor"}:
            raise DecisionAuthorityError(f"Decision {decision_id} has an invalid owner")
        if not isinstance(decision["enforcement"], list) or not decision["enforcement"]:
            raise DecisionAuthorityError(f"Decision {decision_id} has no enforcement")
        known[decision_id] = decision

    searchable = [root / "AGENTS.md", *(root / path for path in sorted(active_documents))]
    owner_locations: dict[str, list[str]] = {decision_id: [] for decision_id in known}
    references: list[tuple[str, str]] = []
    for path in searchable:
        if not path.is_file():
            raise DecisionAuthorityError(f"Registered active document is missing: {path}")
        text = path.read_text(encoding="utf-8")
        relative = path.relative_to(root).as_posix()
        for decision_id in OWNER.findall(text):
            if decision_id not in known:
                raise DecisionAuthorityError(
                    f"Unknown decision owner marker {decision_id} in {relative}"
                )
            owner_locations[decision_id].append(relative)
        references.extend((decision_id, relative) for decision_id in REFERENCE.findall(text))

    for decision_id, decision in known.items():
        owner = decision["owner"]
        owner_path = owner["path"]
        if owner_path.startswith("Docs/architecture/") and owner_path not in active_documents:
            raise DecisionAuthorityError(
                f"Decision {decision_id} owner is not in the active architecture index: {owner_path}"
            )
        path = root / owner_path
        if not path.is_file():
            raise DecisionAuthorityError(f"Decision {decision_id} owner is missing: {owner_path}")
        heading = f"## {owner['anchor']}"
        owner_text = path.read_text(encoding="utf-8")
        if owner_text.count(heading) != 1:
            raise DecisionAuthorityError(
                f"Decision {decision_id} owner anchor must be unique: "
                f"{owner_path}#{owner['anchor']}"
            )
        section_start = owner_text.index(heading) + len(heading)
        next_heading = owner_text.find("\n## ", section_start)
        section = owner_text[section_start:next_heading if next_heading >= 0 else None]
        marker = f"<!-- decision-owner: {decision_id} -->"
        if section.count(marker) != 1:
            raise DecisionAuthorityError(
                f"Decision {decision_id} owner marker is outside its canonical section: "
                f"{owner_path}#{owner['anchor']}"
            )
        locations = owner_locations[decision_id]
        if locations != [owner_path]:
            raise DecisionAuthorityError(
                f"Decision {decision_id} must have exactly one owner marker in {owner_path}; found {locations}"
            )
        for enforcement in decision["enforcement"]:
            if not isinstance(enforcement, str) or not (root / enforcement).is_file():
                raise DecisionAuthorityError(
                    f"Decision {decision_id} enforcement is missing: {enforcement!r}"
                )

    for decision_id, relative in references:
        if decision_id not in known:
            raise DecisionAuthorityError(
                f"Unknown decision reference {decision_id} in {relative}"
            )


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(__file__).resolve().parents[1]
    try:
        validate(root)
    except DecisionAuthorityError as error:
        print(f"decision authority validation failed: {error}", file=sys.stderr)
        return 1
    print("decision authority validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
