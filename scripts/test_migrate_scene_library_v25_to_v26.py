#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_library_v25_to_v26.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v26", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationV26Tests(unittest.TestCase):
    def fixture(self) -> dict:
        scenes = []
        for suffix, motion in (("1", None), ("2", {"user": "motion"})):
            scenes.append({
                "id": f"00000000-0000-0000-0000-00000000000{suffix}",
                "name": f"User Scene {suffix}",
                "snapshot": {
                    "schema": "ScreenSimulation.SavedScene.v24",
                    "authoring": {"user": suffix},
                    "fusionTrackerMotion": motion,
                },
            })
        return {
            "schemaVersion": 25,
            "scenes": scenes,
            "productions": [{
                "id": "00000000-0000-0000-0000-000000000010",
                "name": "User Production",
                "episodes": [{
                    "id": "00000000-0000-0000-0000-000000000011",
                    "name": "User Episode",
                    "shots": [{
                        "id": "00000000-0000-0000-0000-000000000012",
                        "name": "User Shot",
                        "scenes": [
                            {"sceneID": scenes[0]["id"], "ordinal": 1},
                            {"sceneID": scenes[1]["id"], "ordinal": 2},
                        ],
                    }],
                }],
            }],
            "unclassifiedSceneIDs": [],
        }

    def test_preserves_every_user_collection_and_materializes_prior_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v25.json", root / "Scenes.v26.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 26)
            self.assertEqual(result["productions"], fixture["productions"])
            self.assertEqual(result["unclassifiedSceneIDs"], [])
            self.assertEqual(result["scenes"][0]["snapshot"]["trackingSceneMethod"], "fusionComposition")
            self.assertEqual(result["scenes"][1]["snapshot"]["trackingSceneMethod"], "fusionTrackerClipboard")
            for index, scene in enumerate(result["scenes"]):
                expected = fixture["scenes"][index]["snapshot"].copy()
                expected["schema"] = "ScreenSimulation.SavedScene.v25"
                expected["trackingSceneMethod"] = scene["snapshot"]["trackingSceneMethod"]
                self.assertEqual(scene["snapshot"], expected)
            self.assertEqual(backup.read_bytes(), original)

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v25.json", root / "Scenes.v26.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])


if __name__ == "__main__":
    unittest.main()
