#!/usr/bin/env python3

import base64
import json
import tempfile
import unittest
import uuid
from pathlib import Path

from migrate_scene_library_v1_v2_to_v3 import (
    CANONICAL_STAGE_IDS,
    CURRENT_SCENE_SCHEMA,
    CURRENT_SETTINGS_SCHEMA,
    MigrationError,
    migrate,
)


class SceneLibraryMigrationTests(unittest.TestCase):
    def retired_library(self, root: Path, frame_rate=25) -> str:
        scene_id = uuid.uuid4()
        settings = {
            "settings": {
                "schema": "ScreenSimulation.FrameSettings.v14",
                "context": {
                    "selection": {"frameRate": frame_rate},
                    "previewPhaseID": "sensor-noise",
                },
                "stages": [
                    ({"stageID": stage_id, "kind": "discrete", "enabled": True}
                     if stage_id in (0x204, 0x206)
                     else {"stageID": stage_id, "kind": "continuous",
                           "storedAmount": 1, "bypassed": False})
                    for stage_id in [
                        0x101, 0x102, 0x108, 0x103, 0x104, 0x201, 0x105, 0x106,
                        0x107, 0x202, 0x203, 0x208, 0x207, 0x204, 0x205, 0x206,
                    ]
                ],
            }
        }
        encoded = base64.b64encode(json.dumps(settings).encode()).decode()
        thumbnail = f"{str(scene_id).lower()}.png"
        (root / thumbnail).write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        document = {
            "schemaVersion": 1,
            "scenes": [{
                "id": str(scene_id).upper(),
                "name": "Fixture",
                "thumbnailFileName": thumbnail,
                "snapshot": {
                    "schema": "ScreenSimulation.SavedScene.v1",
                    "source": {"kind": "syntheticPattern", "patternRawValue": 6, "assets": []},
                    "currentFrame": 0,
                    "viewerZoom": 1,
                    "viewerPanX": 0,
                    "viewerPanY": 0,
                    "viewerIsFitted": True,
                    "settingsDocument": encoded,
                },
            }],
        }
        (root / "Scenes.v1.json").write_text(json.dumps(document))
        return thumbnail

    def test_migrates_explicit_stage_and_time_contracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            thumbnail = self.retired_library(source)
            output = migrate(source, destination)
            document = json.loads(output.read_text())
            snapshot = document["scenes"][0]["snapshot"]
            settings = json.loads(base64.b64decode(snapshot["settingsDocument"]))["settings"]
            self.assertEqual(document["schemaVersion"], 3)
            self.assertEqual(snapshot["schema"], CURRENT_SCENE_SCHEMA)
            self.assertEqual(settings["schema"], CURRENT_SETTINGS_SCHEMA)
            self.assertEqual(settings["context"]["selection"]["frameRate"], {
                "numerator": 25, "denominator": 1,
            })
            self.assertEqual(settings["context"]["previewPhaseID"], "sensor-readout-raw")
            self.assertEqual([stage["stageID"] for stage in settings["stages"]], CANONICAL_STAGE_IDS)
            self.assertEqual(settings["stages"][12]["kind"], "continuous")
            self.assertEqual(settings["stages"][14]["kind"], "discrete")
            self.assertTrue((destination / thumbnail).is_file())
            self.assertFalse((destination / "Scenes.v1.json").exists())

    def test_rejects_nonexact_retired_frame_rate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            self.retired_library(source, frame_rate=23.976)
            with self.assertRaises(MigrationError):
                migrate(source, root / "destination")


if __name__ == "__main__":
    unittest.main()
