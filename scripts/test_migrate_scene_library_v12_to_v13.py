#!/usr/bin/env python3

import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_scene_library_v12_to_v13.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v13", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


def library(cover_id: str = "cover-matte-ar") -> dict:
    settings = {
        "settings": {
            "schema": "ScreenSimulation.FrameSettings.v23",
            "pipeline": {"coverGlass": {"id": cover_id}},
            "context": {"selection": {"coverGlassPresetID": cover_id}},
        }
    }
    return {
        "schemaVersion": 12,
        "scenes": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Fixture",
            "thumbnailFileName": "00000000-0000-0000-0000-000000000001.png",
            "snapshot": {
                "schema": "ScreenSimulation.SavedScene.v12",
                "source": {"kind": "syntheticPattern", "patternRawValue": 6, "assets": []},
                "currentFrame": 0, "viewerZoom": 1, "viewerPanX": 0, "viewerPanY": 0,
                "viewerIsFitted": True,
                "settingsDocument": base64.b64encode(json.dumps(settings).encode()).decode(),
                "generatedEnvironment": None, "tracking": None,
            },
        }],
    }


class SceneLibraryMigrationTests(unittest.TestCase):
    def test_materializes_explicit_glow_threshold_in_both_authorities(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v12.json", root / "Scenes.v13.json"
            source.write_text(json.dumps(library()), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 13)
            snapshot = result["scenes"][0]["snapshot"]
            self.assertEqual(snapshot["schema"], "ScreenSimulation.SavedScene.v13")
            settings = json.loads(base64.b64decode(snapshot["settingsDocument"]))["settings"]
            self.assertEqual(settings["schema"], "ScreenSimulation.FrameSettings.v24")
            self.assertEqual(settings["context"]["selection"]["coverGlowThresholdRelativeWhite"], .15)
            self.assertEqual(settings["pipeline"]["coverGlass"]["glowThresholdRelativeWhite"], .15)

    def test_custom_cover_requires_explicit_authored_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v12.json"
            source.write_text(json.dumps(library("custom-cover")), encoding="utf-8")
            with self.assertRaises(ValueError):
                MIGRATION.migrated_document(source)
            result = MIGRATION.migrated_document(source, {"custom-cover": .33})
            encoded = result["scenes"][0]["snapshot"]["settingsDocument"]
            settings = json.loads(base64.b64decode(encoded))["settings"]
            self.assertEqual(settings["pipeline"]["coverGlass"]["glowThresholdRelativeWhite"], .33)


if __name__ == "__main__":
    unittest.main()
