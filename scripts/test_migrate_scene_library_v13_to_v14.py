#!/usr/bin/env python3

import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_scene_library_v13_to_v14.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v14", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


def library() -> dict:
    old_selection = {
        "coverGlowScatterFraction": .12, "coverGlowCoreRadiusMillimeters": .4,
        "coverGlowTailRadiusMillimeters": 3.5, "coverGlowTailFraction": .5,
    }
    old_cover = {
        "glowScatterFraction": .12, "glowCoreRadiusMillimeters": .4,
        "glowTailRadiusMillimeters": 3.5, "glowTailFraction": .5,
    }
    settings = {"settings": {
        "schema": "ScreenSimulation.FrameSettings.v24",
        "pipeline": {"coverGlass": old_cover},
        "context": {"selection": old_selection},
    }}
    return {"schemaVersion": 13, "scenes": [{
        "id": "00000000-0000-0000-0000-000000000001", "name": "Fixture",
        "thumbnailFileName": "00000000-0000-0000-0000-000000000001.png",
        "snapshot": {
            "schema": "ScreenSimulation.SavedScene.v13", "source": {}, "currentFrame": 0,
            "viewerZoom": 1, "viewerPanX": 0, "viewerPanY": 0, "viewerIsFitted": True,
            "settingsDocument": base64.b64encode(json.dumps(settings).encode()).decode(),
            "generatedEnvironment": None, "tracking": None,
        },
    }]}


class SceneLibraryMigrationTests(unittest.TestCase):
    def test_replaces_retired_glow_shape_without_mutating_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v13.json", root / "Scenes.v14.json"
            original = library()
            source.write_text(json.dumps(original), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(destination.read_text())
            snapshot = result["scenes"][0]["snapshot"]
            settings = json.loads(base64.b64decode(snapshot["settingsDocument"]))["settings"]
            self.assertEqual(result["schemaVersion"], 14)
            self.assertEqual(snapshot["schema"], "ScreenSimulation.SavedScene.v14")
            self.assertEqual(settings["schema"], "ScreenSimulation.FrameSettings.v25")
            self.assertEqual(settings["context"]["selection"]["coverGlowIntensity"], .12)
            self.assertEqual(settings["context"]["selection"]["coverGlowRadiusMillimeters"], 3.5)
            self.assertEqual(settings["pipeline"]["coverGlass"]["glowIntensity"], .12)
            self.assertEqual(settings["pipeline"]["coverGlass"]["glowRadiusMillimeters"], 3.5)


if __name__ == "__main__":
    unittest.main()
