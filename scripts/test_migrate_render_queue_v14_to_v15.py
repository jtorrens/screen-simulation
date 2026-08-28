#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_render_queue_v14_to_v15.py")
SPEC = importlib.util.spec_from_file_location("queue_migration_v15", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class RenderQueueMigrationV15Tests(unittest.TestCase):
    def fixture(self) -> dict:
        return {
            "schema": "ScreenSimulation.RenderQueue.v14",
            "isPaused": True,
            "jobs": [{
                "id": "user-job",
                "state": "completed",
                "scene": {
                    "id": "00000000-0000-0000-0000-000000000002",
                    "snapshot": {
                        "schema": "ScreenSimulation.SavedScene.v25",
                        "authoring": {"user": "unchanged"},
                    },
                },
                "configuration": {"user": "unchanged"},
            }],
        }

    def test_preserves_jobs_and_adds_constant_opacity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "RenderQueue.v14.json", root / "RenderQueue.v15.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schema"], "ScreenSimulation.RenderQueue.v15")
            self.assertTrue(result["isPaused"])
            self.assertEqual(result["jobs"][0]["configuration"], {"user": "unchanged"})
            snapshot = result["jobs"][0]["scene"]["snapshot"]
            self.assertEqual(snapshot["schema"], "ScreenSimulation.SavedScene.v26")
            self.assertEqual(
                snapshot["animation"]["scalarTracks"][0]["keyframes"][0]["value"], 1.0
            )
            self.assertEqual(backup.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
