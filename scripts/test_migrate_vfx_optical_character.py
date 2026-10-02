import json
import tempfile
import unittest
from pathlib import Path

from migrate_render_queue_v17_to_v18 import migrate as migrate_queue
from migrate_scene_autosaves_v27_to_v28 import migrate as migrate_autosaves
from migrate_scene_library_v30_to_v31 import migrate as migrate_scenes


def snapshot():
    return {
        "schema": "ScreenSimulation.SavedScene.v28",
        "id": "authored-snapshot",
        "authoring": {
            "schema": "ScreenSimulation.SceneAuthoring.v5",
            "activeModel": "vfx-continuity",
            "vfxContinuity": {"relativePanelLevel": 1.75},
            "profiles": {"deviceID": "user-device", "cameraID": "user-camera"},
            "overrides": [{"id": "user-override", "value": 1.75}],
            "modelOverrides": {"locked": False, "custom": "preserve-me"},
            "context": {"source": "user-source", "reference": "user-reference"},
        },
        "animation": {"tracks": [{"id": "user-track"}]},
        "resources": [{"id": "user-resource"}],
    }


class VfxOpticalCharacterMigrationTests(unittest.TestCase):
    def test_all_embedded_scenes_receive_neutral_controls_and_preserve_authored_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scenes_source = root / "Scenes.v30.json"
            scenes_destination = root / "Scenes.v31.json"
            original_snapshot = snapshot()
            scenes = {
                "schemaVersion": 30,
                "scenes": [{
                    "id": "user-scene", "name": "User scene",
                    "snapshot": original_snapshot, "thumbnail": "user-thumbnail.png",
                }],
                "productions": [{
                    "id": "user-production",
                    "episodes": [{"id": "user-episode", "shots": [{
                        "id": "user-shot", "sceneIDs": ["user-scene"], "locked": False,
                    }]}],
                }],
                "unclassifiedSceneIDs": [],
            }
            scenes_source.write_text(json.dumps(scenes), encoding="utf-8")
            original_bytes = scenes_source.read_bytes()
            backup = migrate_scenes(scenes_source, scenes_destination)
            migrated = json.loads(scenes_destination.read_text(encoding="utf-8"))

            self.assertEqual(backup.read_bytes(), original_bytes)
            self.assertEqual(migrated["schemaVersion"], 31)
            self.assertEqual(migrated["productions"], scenes["productions"])
            self.assertEqual(migrated["unclassifiedSceneIDs"], [])
            migrated_snapshot = migrated["scenes"][0]["snapshot"]
            self.assertEqual(migrated_snapshot["schema"], "ScreenSimulation.SavedScene.v29")
            self.assertEqual(migrated_snapshot["authoring"]["schema"],
                             "ScreenSimulation.SceneAuthoring.v6")
            self.assertEqual(migrated_snapshot["authoring"]["activeModel"], "vfx-continuity")
            self.assertEqual(migrated_snapshot["authoring"]["vfxContinuity"], {
                "relativePanelLevel": 1.75,
                "emissionPresence": 1.0,
                "chromaticFringe": 1.0,
            })
            for key in ("profiles", "overrides", "modelOverrides", "context"):
                self.assertEqual(migrated_snapshot["authoring"][key],
                                 original_snapshot["authoring"][key])
            self.assertEqual(migrated_snapshot["animation"], original_snapshot["animation"])
            self.assertEqual(migrated_snapshot["resources"], original_snapshot["resources"])

            queue_source = root / "RenderQueue.v17.json"
            queue_destination = root / "RenderQueue.v18.json"
            queue = {
                "schema": "ScreenSimulation.RenderQueue.v17", "isPaused": True,
                "jobs": [{"id": "user-job", "state": "pending",
                          "scene": {"id": "frozen-scene", "snapshot": snapshot()}}],
            }
            queue_source.write_text(json.dumps(queue), encoding="utf-8")
            queue_original = queue_source.read_bytes()
            queue_backup = migrate_queue(queue_source, queue_destination)
            migrated_queue = json.loads(queue_destination.read_text(encoding="utf-8"))
            self.assertEqual(queue_backup.read_bytes(), queue_original)
            self.assertEqual(migrated_queue["schema"], "ScreenSimulation.RenderQueue.v18")
            self.assertEqual(
                migrated_queue["jobs"][0]["scene"]["snapshot"]["authoring"]["vfxContinuity"],
                {"relativePanelLevel": 1.75, "emissionPresence": 1.0,
                 "chromaticFringe": 1.0},
            )

            autosaves_source = root / "Autosave.v27"
            autosaves_destination = root / "Autosave.v28"
            scene_folder = autosaves_source / "user-scene"
            scene_folder.mkdir(parents=True)
            revision = {
                "schema": "ScreenSimulation.SceneAutosave.v5",
                "id": "user-revision", "snapshot": snapshot(),
            }
            (scene_folder / "revision.json").write_text(json.dumps(revision), encoding="utf-8")
            (scene_folder / "user-thumbnail.png").write_bytes(b"user-thumbnail")
            autosave_backup = migrate_autosaves(autosaves_source, autosaves_destination)
            self.assertEqual((autosave_backup / "user-scene/user-thumbnail.png").read_bytes(),
                             b"user-thumbnail")
            self.assertEqual((autosaves_destination / "user-scene/user-thumbnail.png").read_bytes(),
                             b"user-thumbnail")
            migrated_revision = json.loads(
                (autosaves_destination / "user-scene/revision.json").read_text(encoding="utf-8")
            )
            self.assertEqual(migrated_revision["schema"], "ScreenSimulation.SceneAutosave.v6")
            self.assertEqual(migrated_revision["snapshot"]["schema"],
                             "ScreenSimulation.SavedScene.v29")

    def test_rejects_unknown_or_already_extended_vfx_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Scenes.v30.json"
            invalid = snapshot()
            invalid["authoring"]["vfxContinuity"]["emissionPresence"] = 1.0
            source.write_text(json.dumps({
                "schemaVersion": 30,
                "scenes": [{"snapshot": invalid}],
                "productions": [], "unclassifiedSceneIDs": [],
            }), encoding="utf-8")
            with self.assertRaises(ValueError):
                migrate_scenes(source, root / "Scenes.v31.json")


if __name__ == "__main__":
    unittest.main()
