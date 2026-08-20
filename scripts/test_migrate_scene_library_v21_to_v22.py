#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_scene_library_v21_to_v22.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v22", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationTests(unittest.TestCase):
    def fixture(self, overrides=None) -> dict:
        return {
            "schemaVersion": 21,
            "scenes": [{
                "id": "scene",
                "snapshot": {
                    "schema": "ScreenSimulation.SavedScene.v21",
                    "authoring": {"overrides": overrides or []},
                },
            }],
        }

    def test_preserves_scene_and_advances_current_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Scenes.v21.json"
            destination = root / "Scenes.v22.json"
            original = self.fixture()
            source.write_text(json.dumps(original), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 22)
            self.assertEqual(
                result["scenes"][0]["snapshot"]["schema"],
                "ScreenSimulation.SavedScene.v22",
            )

    def test_converts_only_exact_conformal_v21_transform(self) -> None:
        overrides = [
            {"controlID": "environment-tangent-m00", "kind": "scalar", "scalar": 0.5},
            {"controlID": "environment-tangent-m01", "kind": "scalar", "scalar": -0.2},
            {"controlID": "environment-tangent-m10", "kind": "scalar", "scalar": 0.2},
            {"controlID": "environment-tangent-m11", "kind": "scalar", "scalar": 0.5},
        ]
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v21.json"
            source.write_text(json.dumps(self.fixture(overrides)), encoding="utf-8")
            result = MIGRATION.migrated_document(source)
            values = {
                item["controlID"]: item["scalar"]
                for item in result["scenes"][0]["snapshot"]["authoring"]["overrides"]
            }
            self.assertEqual(values["environment-mobius-a-real"], 0.5)
            self.assertEqual(values["environment-mobius-a-imag"], 0.2)
            self.assertEqual(values["environment-mobius-c-real"], 0.0)
            self.assertEqual(values["environment-mobius-c-imag"], 0.0)


if __name__ == "__main__":
    unittest.main()
