#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_library_v23_to_v24.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v24", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationV24Tests(unittest.TestCase):
    def fixture(self) -> dict:
        return {"schemaVersion": 23, "scenes": [
            {"id": "00000000-0000-0000-0000-000000000001", "name": "B", "snapshot": {"schema": "ScreenSimulation.SavedScene.v23"}},
            {"id": "00000000-0000-0000-0000-000000000002", "name": "A", "snapshot": {"schema": "ScreenSimulation.SavedScene.v23"}},
        ]}

    def test_preserves_scene_records_and_order_and_creates_exact_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v23.json", root / "Scenes.v24.json"
            source.write_text(json.dumps(self.fixture(), separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 24)
            self.assertEqual(result["scenes"], self.fixture()["scenes"])
            self.assertEqual(result["unclassifiedSceneIDs"], [scene["id"] for scene in self.fixture()["scenes"]])
            self.assertEqual(result["productions"], [])
            self.assertEqual(backup.read_bytes(), original)

    def test_refuses_existing_destination_before_creating_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v23.json", root / "Scenes.v24.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            with self.assertRaises(ValueError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])

    def test_rejects_malformed_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v23.json"
            source.write_text(json.dumps({"schemaVersion": 23, "scenes": [], "extra": True}))
            with self.assertRaises(ValueError):
                MIGRATION.migrated_document(source)


if __name__ == "__main__":
    unittest.main()
