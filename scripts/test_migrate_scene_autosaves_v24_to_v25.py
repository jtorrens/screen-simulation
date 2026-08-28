#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_autosaves_v24_to_v25.py")
SPEC = importlib.util.spec_from_file_location("autosave_migration_v25", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneAutosaveMigrationV25Tests(unittest.TestCase):
    def revision(self) -> dict:
        return {
            "schema": "ScreenSimulation.SceneAutosave.v2",
            "id": "revision",
            "originalSceneID": "00000000-0000-0000-0000-000000000003",
            "snapshot": {
                "schema": "ScreenSimulation.SavedScene.v25",
                "authoring": {"user": "unchanged"},
            },
        }

    def test_preserves_revisions_and_non_json_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Autosave.v24", root / "Autosave.v25"
            directory = source / "scene"
            directory.mkdir(parents=True)
            (directory / "revision.json").write_text(json.dumps(self.revision()))
            (directory / "thumbnail.png").write_bytes(b"user-thumbnail")
            original = MIGRATION.tree_bytes(source)
            backup = MIGRATION.migrate(source, destination)
            self.assertEqual(MIGRATION.tree_bytes(backup), original)
            self.assertEqual((destination / "scene/thumbnail.png").read_bytes(), b"user-thumbnail")
            result = json.loads((destination / "scene/revision.json").read_text())
            self.assertEqual(result["schema"], "ScreenSimulation.SceneAutosave.v3")
            self.assertEqual(result["snapshot"]["schema"], "ScreenSimulation.SavedScene.v26")
            self.assertEqual(result["snapshot"]["authoring"], {"user": "unchanged"})
            self.assertEqual(
                result["snapshot"]["animation"]["scalarTracks"][0]["propertyID"],
                "simulation-opacity",
            )


if __name__ == "__main__":
    unittest.main()
