#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_render_queue_v11_to_v12.py")
SPEC = importlib.util.spec_from_file_location("queue_migration_v12", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class RenderQueueMigrationV12Tests(unittest.TestCase):
    def fixture(self) -> dict:
        def job(suffix: str, motion: object) -> dict:
            return {
                "id": f"user-job-{suffix}",
                "state": "completed",
                "scene": {
                    "id": f"user-scene-{suffix}",
                    "name": f"User Scene {suffix}",
                    "snapshot": {
                        "schema": "ScreenSimulation.SavedScene.v24",
                        "authoring": {"user": suffix},
                        "fusionTrackerMotion": motion,
                    },
                },
                "configuration": {"user": suffix},
            }
        return {
            "schema": "ScreenSimulation.RenderQueue.v11",
            "isPaused": True,
            "jobs": [job("fusion", None), job("tracker", {"user": "motion"})],
        }

    def test_preserves_every_job_and_materializes_prior_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "RenderQueue.v11.json", root / "RenderQueue.v12.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schema"], "ScreenSimulation.RenderQueue.v12")
            self.assertTrue(result["isPaused"])
            self.assertEqual([job["id"] for job in result["jobs"]], [
                "user-job-fusion", "user-job-tracker"
            ])
            self.assertEqual(result["jobs"][0]["scene"]["snapshot"]["trackingSceneMethod"], "fusionComposition")
            self.assertEqual(result["jobs"][1]["scene"]["snapshot"]["trackingSceneMethod"], "fusionTrackerClipboard")
            self.assertEqual(backup.read_bytes(), original)

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "RenderQueue.v11.json", root / "RenderQueue.v12.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])


if __name__ == "__main__":
    unittest.main()
