#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_render_queue_v10_to_v11.py")
SPEC = importlib.util.spec_from_file_location("queue_migration_v11", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class RenderQueueMigrationV11Tests(unittest.TestCase):
    def fixture(self) -> dict:
        return {
            "schema": "ScreenSimulation.RenderQueue.v10",
            "isPaused": True,
            "jobs": [{
                "id": "user-job",
                "state": "completed",
                "scene": {
                    "id": "user-scene",
                    "name": "User Scene",
                    "snapshot": {
                        "schema": "ScreenSimulation.SavedScene.v23",
                        "authoring": {"user": "value"},
                    },
                },
                "configuration": {"user": "configuration"},
            }],
        }

    def test_preserves_jobs_and_adds_only_current_motion_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "RenderQueue.v10.json", root / "RenderQueue.v11.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schema"], "ScreenSimulation.RenderQueue.v11")
            expected = fixture["jobs"][0].copy()
            expected["scene"] = fixture["jobs"][0]["scene"].copy()
            expected["scene"]["snapshot"] = fixture["jobs"][0]["scene"]["snapshot"].copy()
            expected["scene"]["snapshot"]["schema"] = "ScreenSimulation.SavedScene.v24"
            expected["scene"]["snapshot"]["fusionTrackerMotion"] = None
            self.assertEqual(result["jobs"], [expected])
            self.assertTrue(result["isPaused"])
            self.assertEqual(backup.read_bytes(), original)

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "RenderQueue.v10.json", root / "RenderQueue.v11.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])


if __name__ == "__main__":
    unittest.main()
