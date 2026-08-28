#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_autosaves_v23_to_v24.py")
SPEC = importlib.util.spec_from_file_location("autosave_migration_v24", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneAutosaveMigrationV24Tests(unittest.TestCase):
    def revision(self, motion: object, snapshot_schema: str = "ScreenSimulation.SavedScene.v24") -> dict:
        snapshot = {
            "schema": snapshot_schema,
            "authoring": {"user": "value"},
        }
        if snapshot_schema == "ScreenSimulation.SavedScene.v24":
            snapshot["fusionTrackerMotion"] = motion
        return {
            "schema": "ScreenSimulation.SceneAutosave.v1",
            "id": "revision",
            "snapshot": snapshot,
        }

    def test_preserves_every_scene_revision_and_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Autosave.v23", root / "Autosave.v24"
            for scene, motion, schema in (
                ("scene-a", None, "ScreenSimulation.SavedScene.v24"),
                ("scene-b", {"user": "motion"}, "ScreenSimulation.SavedScene.v24"),
                ("scene-c", None, "ScreenSimulation.SavedScene.v23"),
            ):
                directory = source / scene
                directory.mkdir(parents=True)
                (directory / "revision.json").write_text(json.dumps(self.revision(motion, schema)))
                (directory / "thumbnail.png").write_bytes(f"png-{scene}".encode())
                (directory / "environment.exr").write_bytes(f"exr-{scene}".encode())
            original = MIGRATION.tree_bytes(source)
            backup = MIGRATION.migrate(source, destination)
            self.assertEqual(MIGRATION.tree_bytes(backup), original)
            self.assertEqual((destination / "scene-a/thumbnail.png").read_bytes(), b"png-scene-a")
            self.assertEqual((destination / "scene-b/environment.exr").read_bytes(), b"exr-scene-b")
            first = json.loads((destination / "scene-a/revision.json").read_text())
            second = json.loads((destination / "scene-b/revision.json").read_text())
            third = json.loads((destination / "scene-c/revision.json").read_text())
            self.assertEqual(first["schema"], "ScreenSimulation.SceneAutosave.v2")
            self.assertEqual(first["snapshot"]["schema"], "ScreenSimulation.SavedScene.v25")
            self.assertEqual(first["snapshot"]["trackingSceneMethod"], "fusionComposition")
            self.assertEqual(second["snapshot"]["trackingSceneMethod"], "fusionTrackerClipboard")
            self.assertEqual(third["snapshot"]["fusionTrackerMotion"], None)
            self.assertEqual(third["snapshot"]["trackingSceneMethod"], "fusionComposition")

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Autosave.v23", root / "Autosave.v24"
            source.mkdir()
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination)
            self.assertEqual(list(root.glob("*.backup-*")), [])


if __name__ == "__main__":
    unittest.main()
