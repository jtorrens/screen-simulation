#!/usr/bin/env python3

import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_scene_library_v14_to_v15.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v15", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


def library() -> dict:
    settings = {"settings": {
        "schema": "ScreenSimulation.FrameSettings.v25",
        "pipeline": {"coverGlass": {}, "moireIntensity": 1},
        "context": {"selection": {"moireIntensity": 1}},
    }}
    return {"schemaVersion": 14, "scenes": [{
        "id": "00000000-0000-0000-0000-000000000001", "name": "Fixture",
        "thumbnailFileName": "00000000-0000-0000-0000-000000000001.png",
        "snapshot": {
            "schema": "ScreenSimulation.SavedScene.v14", "source": {}, "currentFrame": 0,
            "viewerZoom": 1, "viewerPanX": 0, "viewerPanY": 0, "viewerIsFitted": True,
            "settingsDocument": base64.b64encode(json.dumps(settings).encode()).decode(),
            "generatedEnvironment": None, "tracking": None,
        },
    }]}


class SceneLibraryMigrationTests(unittest.TestCase):
    def test_adds_explicit_exterior_spill_without_mutating_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v14.json", root / "Scenes.v15.json"
            original = library()
            source.write_text(json.dumps(original), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(destination.read_text())
            snapshot = result["scenes"][0]["snapshot"]
            settings = json.loads(base64.b64decode(snapshot["settingsDocument"]))["settings"]
            self.assertEqual(result["schemaVersion"], 15)
            self.assertEqual(snapshot["schema"], "ScreenSimulation.SavedScene.v15")
            self.assertEqual(settings["schema"], "ScreenSimulation.FrameSettings.v26")
            self.assertEqual(settings["context"]["selection"]["coverGlowExteriorIntensity"], 1.0)
            self.assertEqual(settings["pipeline"]["coverGlowExteriorIntensity"], 1.0)


if __name__ == "__main__":
    unittest.main()
