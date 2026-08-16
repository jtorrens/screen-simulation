#!/usr/bin/env python3

import base64
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_scene_library_v11_to_v12.py")
SPEC = importlib.util.spec_from_file_location("scene_migration", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


def encoded_settings() -> str:
    document = {
        "settings": {
            "schema": "ScreenSimulation.FrameSettings.v22",
            "pipeline": {"cameraID": "fixture"},
            "context": {
                "selection": {
                    "deviceID": "fixture",
                    "deviceVfxAlphaModeID": "ignore",
                }
            },
        }
    }
    return base64.b64encode(
        json.dumps(document, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")


def library() -> dict:
    return {
        "schemaVersion": 11,
        "scenes": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Fixture",
            "thumbnailFileName": "00000000-0000-0000-0000-000000000001.png",
            "snapshot": {
                "schema": "ScreenSimulation.SavedScene.v11",
                "source": {"kind": "syntheticPattern", "patternRawValue": 6, "assets": []},
                "currentFrame": 0,
                "viewerZoom": 1,
                "viewerPanX": 0,
                "viewerPanY": 0,
                "viewerIsFitted": True,
                "settingsDocument": encoded_settings(),
                "generatedEnvironment": None,
                "tracking": None,
            },
        }],
    }


class SceneLibraryMigrationTests(unittest.TestCase):
    def test_materializes_pipeline_alpha_from_explicit_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Scenes.v11.json"
            destination = root / "Scenes.v12.json"
            original = json.dumps(library(), indent=2).encode("utf-8")
            source.write_bytes(original)

            MIGRATION.migrate(source, destination)

            self.assertEqual(source.read_bytes(), original)
            result = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(result["schemaVersion"], 12)
            snapshot = result["scenes"][0]["snapshot"]
            self.assertEqual(snapshot["schema"], "ScreenSimulation.SavedScene.v12")
            settings = json.loads(base64.b64decode(snapshot["settingsDocument"], validate=True))["settings"]
            self.assertEqual(settings["schema"], "ScreenSimulation.FrameSettings.v23")
            self.assertEqual(settings["pipeline"]["deviceVfxAlphaMode"], "ignore")
            self.assertEqual(settings["context"]["selection"]["deviceVfxAlphaModeID"], "ignore")

    def test_rejects_ambiguous_input_without_publishing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Scenes.v11.json"
            destination = root / "Scenes.v12.json"
            malformed = library()
            settings = json.loads(base64.b64decode(
                malformed["scenes"][0]["snapshot"]["settingsDocument"], validate=True
            ))
            settings["settings"]["pipeline"]["deviceVfxAlphaMode"] = "ignore"
            malformed["scenes"][0]["snapshot"]["settingsDocument"] = base64.b64encode(
                json.dumps(settings).encode("utf-8")
            ).decode("ascii")
            source.write_text(json.dumps(malformed), encoding="utf-8")

            with self.assertRaises(ValueError):
                MIGRATION.migrate(source, destination)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
