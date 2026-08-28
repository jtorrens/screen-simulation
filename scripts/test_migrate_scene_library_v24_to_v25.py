#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_library_v24_to_v25.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v25", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationV25Tests(unittest.TestCase):
    def fixture(self) -> dict:
        snapshot = {
            "schema": "ScreenSimulation.SavedScene.v23",
            "source": {"kind": "syntheticPattern"},
            "authoring": {"schema": "ScreenSimulation.SceneAuthoring.v4"},
        }
        return {
            "schemaVersion": 24,
            "scenes": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "User Scene", "snapshot": snapshot,
            }],
            "productions": [{
                "id": "00000000-0000-0000-0000-000000000010",
                "name": "User Production",
                "episodes": [{
                    "id": "00000000-0000-0000-0000-000000000011",
                    "name": "User Episode",
                    "shots": [{
                        "id": "00000000-0000-0000-0000-000000000012",
                        "name": "User Shot",
                        "scenes": [{
                            "sceneID": "00000000-0000-0000-0000-000000000001",
                            "ordinal": 1,
                        }],
                    }],
                }],
            }],
            "unclassifiedSceneIDs": [],
        }

    def test_preserves_every_user_collection_and_adds_only_current_motion_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v24.json", root / "Scenes.v25.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 25)
            self.assertEqual(result["productions"], fixture["productions"])
            self.assertEqual(result["unclassifiedSceneIDs"], fixture["unclassifiedSceneIDs"])
            expected_scene = fixture["scenes"][0].copy()
            expected_scene["snapshot"] = fixture["scenes"][0]["snapshot"].copy()
            expected_scene["snapshot"]["schema"] = "ScreenSimulation.SavedScene.v24"
            expected_scene["snapshot"]["fusionTrackerMotion"] = None
            self.assertEqual(result["scenes"], [expected_scene])
            self.assertEqual(backup.read_bytes(), original)

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v24.json", root / "Scenes.v25.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])

    def test_rejects_unknown_tracker_field_in_prior_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v24.json"
            fixture = self.fixture()
            fixture["scenes"][0]["snapshot"]["fusionTrackerMotion"] = None
            source.write_text(json.dumps(fixture), encoding="utf-8")
            with self.assertRaises(ValueError):
                MIGRATION.migrated_document(source)


if __name__ == "__main__":
    unittest.main()
