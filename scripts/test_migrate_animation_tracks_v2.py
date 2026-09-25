import json
import tempfile
import unittest
from pathlib import Path

from migrate_render_queue_v15_to_v16 import migrate as migrate_queue
from migrate_scene_autosaves_v25_to_v26 import migrate as migrate_autosaves
from migrate_scene_library_v28_to_v29 import migrate as migrate_scenes


def snapshot():
    return {
        "schema": "ScreenSimulation.SavedScene.v26",
        "userAuthored": {"locked": False, "value": "preserve-me"},
        "animation": {
            "schema": "ScreenSimulation.SceneAnimation.v1",
            "scalarTracks": [{
                "propertyID": "simulation-opacity",
                "keyframes": [{"id": "key", "timeNumerator": 0,
                               "timeDenominator": 1, "value": 0.75,
                               "interpolation": "linear"}],
            }],
        },
    }


class AnimationV2MigrationTests(unittest.TestCase):
    def test_scene_queue_and_autosave_preserve_authored_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scenes_source, scenes_destination = root / "Scenes.v28.json", root / "Scenes.v29.json"
            scenes = {
                "schemaVersion": 28,
                "scenes": [{"id": "user-scene", "name": "User", "snapshot": snapshot()}],
                "productions": [{"id": "user-production", "episodes": [{"id": "user-episode",
                    "shots": [{"id": "user-shot", "sceneIDs": ["user-scene"]}]}]}],
                "unclassifiedSceneIDs": [],
            }
            scenes_source.write_text(json.dumps(scenes), encoding="utf-8")
            original = scenes_source.read_bytes()
            backup = migrate_scenes(scenes_source, scenes_destination)
            migrated = json.loads(scenes_destination.read_text(encoding="utf-8"))
            self.assertEqual(backup.read_bytes(), original)
            self.assertEqual(migrated["productions"], scenes["productions"])
            self.assertEqual(migrated["scenes"][0]["snapshot"]["userAuthored"],
                             scenes["scenes"][0]["snapshot"]["userAuthored"])
            self.assertEqual(migrated["scenes"][0]["snapshot"]["animation"]["transformTracks"], [])

            queue_source, queue_destination = root / "RenderQueue.v15.json", root / "RenderQueue.v16.json"
            queue = {"schema": "ScreenSimulation.RenderQueue.v15", "isPaused": True,
                     "jobs": [{"id": "user-job", "state": "pending",
                               "scene": {"id": "frozen", "snapshot": snapshot()}}]}
            queue_source.write_text(json.dumps(queue), encoding="utf-8")
            migrate_queue(queue_source, queue_destination)
            migrated_queue = json.loads(queue_destination.read_text(encoding="utf-8"))
            self.assertEqual(migrated_queue["jobs"][0]["state"], "pending")
            self.assertEqual(migrated_queue["jobs"][0]["scene"]["snapshot"]["userAuthored"],
                             {"locked": False, "value": "preserve-me"})

            autosaves_source = root / "Autosave.v25"
            autosaves_destination = root / "Autosave.v26"
            scene_folder = autosaves_source / "user-scene"
            scene_folder.mkdir(parents=True)
            revision = {"schema": "ScreenSimulation.SceneAutosave.v3", "id": "revision",
                        "originalSceneID": "user-scene", "snapshot": snapshot()}
            (scene_folder / "revision.json").write_text(json.dumps(revision), encoding="utf-8")
            (scene_folder / "user.png").write_bytes(b"user-thumbnail")
            migrate_autosaves(autosaves_source, autosaves_destination)
            self.assertEqual((autosaves_destination / "user-scene/user.png").read_bytes(),
                             b"user-thumbnail")
            migrated_revision = json.loads(
                (autosaves_destination / "user-scene/revision.json").read_text(encoding="utf-8")
            )
            self.assertEqual(migrated_revision["snapshot"]["userAuthored"],
                             {"locked": False, "value": "preserve-me"})


if __name__ == "__main__":
    unittest.main()
