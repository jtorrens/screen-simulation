#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_library_v22_to_v23.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v23", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationTests(unittest.TestCase):
    def fixture(self, reference_kind: str) -> dict:
        return {"schemaVersion": 22, "scenes": [{"snapshot": {
            "schema": "ScreenSimulation.SavedScene.v22",
            "authoring": {"schema": "ScreenSimulation.SceneAuthoring.v3", "context": {
                "referenceResource": {"kind": reference_kind}
            }}
        }}]}

    def test_advances_and_materializes_reference_plate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v22.json", root / "Scenes.v23.json"
            source.write_text(json.dumps(self.fixture("imageOrVideo")), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            scene = result["scenes"][0]["snapshot"]
            self.assertEqual(result["schemaVersion"], 23)
            self.assertEqual(scene["schema"], "ScreenSimulation.SavedScene.v23")
            self.assertEqual(scene["authoring"]["schema"], "ScreenSimulation.SceneAuthoring.v4")
            self.assertEqual(scene["authoring"]["context"]["referencePlateID"], "video-reference")

    def test_missing_reference_becomes_explicit_checker_plate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v22.json"
            source.write_text(json.dumps(self.fixture("none")), encoding="utf-8")
            result = MIGRATION.migrated_document(source)
            context = result["scenes"][0]["snapshot"]["authoring"]["context"]
            self.assertEqual(context["referencePlateID"], "vfx-checker")


if __name__ == "__main__":
    unittest.main()
