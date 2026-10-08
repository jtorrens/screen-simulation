import copy
import json
import tempfile
import unittest
from pathlib import Path
from migrate_scene_library_v31_to_v32 import migrate as scenes
from migrate_render_queue_v18_to_v19 import migrate as queue
from migrate_scene_autosaves_v28_to_v29 import migrate as autosaves

class SceneDurationMigrationTests(unittest.TestCase):
    def test_preserves_all_authored_collections_and_source_bytes(self):
        snapshot = {"schema": "ScreenSimulation.SavedScene.v29", "animation": {"user-track": [1, 2]}, "source": {"user-source": "image"}}
        scene = {"id": "user-scene", "name": "Authored", "snapshot": snapshot}
        library = {"schemaVersion": 31, "scenes": [scene, {"id": "user-unclassified", "name": "Unclassified", "snapshot": snapshot}], "productions": [{"id": "user-production", "episodes": [{"id": "user-episode", "shots": [{"id": "user-shot", "locked": True, "sceneIDs": ["user-scene"]}]}]}], "unclassifiedSceneIDs": ["user-unclassified"]}
        jobs = {"schema": "ScreenSimulation.RenderQueue.v18", "isPaused": True, "jobs": [{"id": "user-job", "scene": scene, "configuration": {"firstFrame": 12, "lastFrame": 24}}]}
        revision = {"schema": "ScreenSimulation.SceneAutosave.v6", "id": "user-revision", "snapshot": snapshot}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, original, migrate, new_version in [("scenes", library, scenes, 32), ("queue", jobs, queue, "ScreenSimulation.RenderQueue.v19")]:
                source, target = root / (name + '.json'), root / (name + '-new.json')
                source.write_text(json.dumps(original)); before = source.read_bytes()
                backup = migrate(source, target)
                expected = copy.deepcopy(original)
                expected["schemaVersion" if name == "scenes" else "schema"] = new_version
                frozen = expected["scenes"][0]["snapshot"] if name == "scenes" else expected["jobs"][0]["scene"]["snapshot"]
                frozen.update(schema="ScreenSimulation.SavedScene.v30", durationFrames=None)
                if name == "scenes":
                    expected["scenes"][1]["snapshot"].update(schema="ScreenSimulation.SavedScene.v30", durationFrames=None)
                self.assertEqual(json.loads(target.read_text()), expected)
                self.assertEqual(source.read_bytes(), before)
                self.assertEqual(backup.read_bytes(), before)
            source, target = root / 'autosave', root / 'autosave-new'
            source.mkdir(); (source / 'revision.json').write_text(json.dumps(revision)); (source / 'thumbnail.png').write_bytes(b'user-thumbnail')
            before = (source / 'revision.json').read_bytes()
            autosaves(source, target)
            expected = copy.deepcopy(revision); expected['schema'] = 'ScreenSimulation.SceneAutosave.v7'
            expected['snapshot'].update(schema='ScreenSimulation.SavedScene.v30', durationFrames=None)
            self.assertEqual(json.loads((target / 'revision.json').read_text()), expected)
            self.assertEqual((target / 'thumbnail.png').read_bytes(), b'user-thumbnail')
            self.assertEqual((source / 'revision.json').read_bytes(), before)

if __name__ == '__main__': unittest.main()
