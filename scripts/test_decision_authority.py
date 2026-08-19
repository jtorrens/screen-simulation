#!/usr/bin/env python3
"""Focused tests for the decision-authority coherence gate."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from check_decision_authority import DecisionAuthorityError, validate


class DecisionAuthorityTests(unittest.TestCase):
    def fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "architecture").mkdir()
        (root / "Docs/architecture").mkdir(parents=True)
        (root / "checks").mkdir()
        (root / "AGENTS.md").write_text(
            "# Rules\n\n## Gate\n<!-- decision-owner: repository.gate -->\n",
            encoding="utf-8",
        )
        (root / "Docs/architecture/README.md").write_text(
            "- `policy.md`: policy.\n", encoding="utf-8"
        )
        (root / "Docs/architecture/policy.md").write_text(
            "# Policy\n\n## Scene\n<!-- decision-owner: scene.rule -->\n"
            "<!-- decision-ref: repository.gate -->\n",
            encoding="utf-8",
        )
        (root / "checks/gate.test").write_text("gate", encoding="utf-8")
        manifest = {
            "schema": "screen_simulation_decision_authority",
            "version": 1,
            "decisions": [
                {
                    "id": "repository.gate",
                    "scope": "repository",
                    "owner": {"path": "AGENTS.md", "anchor": "Gate"},
                    "enforcement": ["checks/gate.test"],
                },
                {
                    "id": "scene.rule",
                    "scope": "scene",
                    "owner": {
                        "path": "Docs/architecture/policy.md",
                        "anchor": "Scene",
                    },
                    "enforcement": ["checks/gate.test"],
                },
            ],
        }
        (root / "architecture/decision-authority.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        return root

    def test_valid_single_owner_contract(self) -> None:
        validate(self.fixture())

    def test_duplicate_owner_marker_is_rejected(self) -> None:
        root = self.fixture()
        path = root / "Docs/architecture/policy.md"
        path.write_text(
            path.read_text(encoding="utf-8")
            + "<!-- decision-owner: repository.gate -->\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(DecisionAuthorityError, "exactly one owner marker"):
            validate(root)

    def test_unknown_reference_is_rejected(self) -> None:
        root = self.fixture()
        path = root / "Docs/architecture/policy.md"
        path.write_text(
            path.read_text(encoding="utf-8")
            + "<!-- decision-ref: unknown.rule -->\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(DecisionAuthorityError, "Unknown decision reference"):
            validate(root)

    def test_owner_marker_outside_registered_section_is_rejected(self) -> None:
        root = self.fixture()
        path = root / "Docs/architecture/policy.md"
        path.write_text(
            "# Policy\n<!-- decision-owner: scene.rule -->\n\n## Scene\n"
            "<!-- decision-ref: repository.gate -->\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(DecisionAuthorityError, "outside its canonical section"):
            validate(root)

    def test_owner_outside_active_index_is_rejected(self) -> None:
        root = self.fixture()
        (root / "Docs/architecture/README.md").write_text("# Empty\n", encoding="utf-8")
        with self.assertRaisesRegex(DecisionAuthorityError, "not in the active architecture index"):
            validate(root)

    def test_missing_enforcement_is_rejected(self) -> None:
        root = self.fixture()
        manifest_path = root / "architecture/decision-authority.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["decisions"][0]["enforcement"] = ["checks/missing.test"]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(DecisionAuthorityError, "enforcement is missing"):
            validate(root)


if __name__ == "__main__":
    unittest.main()
