#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_library_v26_to_v27.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v27", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationV27Tests(unittest.TestCase):
    def fixture(self) -> dict:
        scenes = [{
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "User Scene",
            "snapshot": {
                "schema": "ScreenSimulation.SavedScene.v25",
                "authoring": {"user": "unchanged"},
            },
        }]
        return {
            "schemaVersion": 26,
            "scenes": scenes,
            "productions": [{"id": "production", "user": "unchanged"}],
            "unclassifiedSceneIDs": [scenes[0]["id"]],
        }

    def test_preserves_user_data_and_adds_deterministic_identity_track(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v26.json", root / "Scenes.v27.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 27)
            self.assertEqual(result["productions"], fixture["productions"])
            self.assertEqual(result["unclassifiedSceneIDs"], fixture["unclassifiedSceneIDs"])
            snapshot = result["scenes"][0]["snapshot"]
            self.assertEqual(snapshot["schema"], "ScreenSimulation.SavedScene.v26")
            self.assertEqual(snapshot["authoring"], {"user": "unchanged"})
            track = snapshot["animation"]["scalarTracks"][0]
            self.assertEqual(track["propertyID"], "simulation-opacity")
            self.assertEqual(track["keyframes"][0]["value"], 1.0)
            self.assertEqual(
                track["keyframes"][0]["id"],
                MIGRATION.animation_document(fixture["scenes"][0]["id"])
                    ["scalarTracks"][0]["keyframes"][0]["id"],
            )
            self.assertEqual(backup.read_bytes(), original)

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v26.json", root / "Scenes.v27.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])


if __name__ == "__main__":
    unittest.main()
