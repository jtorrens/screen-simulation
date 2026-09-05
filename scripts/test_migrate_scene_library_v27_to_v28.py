#!/usr/bin/env python3

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migrate_scene_library_v27_to_v28.py")
SPEC = importlib.util.spec_from_file_location("scene_migration_v28", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryMigrationV28Tests(unittest.TestCase):
    production_id = "00000000-0000-0000-0000-000000000010"
    episode_id = "00000000-0000-0000-0000-000000000020"

    def fixture(self) -> dict:
        placed_scene = "00000000-0000-0000-0000-000000000001"
        free_scene = "00000000-0000-0000-0000-000000000002"
        return {
            "schemaVersion": 27,
            "scenes": [
                {"id": placed_scene, "name": "User Scene", "snapshot": {"user": "unchanged"}},
                {"id": free_scene, "name": "Free Scene", "snapshot": {"user": "also unchanged"}},
            ],
            "productions": [{
                "id": "00000000-0000-0000-0000-000000000030",
                "name": "User Production",
                "seasonSlug": "S01",
                "association": {"user": "unchanged"},
                "episodes": [{
                    "id": "00000000-0000-0000-0000-000000000040",
                    "name": "EP01",
                    "associationState": "associated",
                    "externalReference": {
                        "productionId": self.production_id,
                        "episodeId": self.episode_id,
                        "episodeOrder": 1,
                        "episodeSlug": "EP01",
                    },
                    "shots": [{
                        "id": "00000000-0000-0000-0000-000000000050",
                        "name": "SH010",
                        "associationState": "associated",
                        "externalReference": {"user": "unchanged"},
                        "nextSceneOrdinal": 2,
                        "scenes": [{"sceneID": placed_scene, "ordinal": 1}],
                    }],
                }],
            }],
            "unclassifiedSceneIDs": [free_scene],
        }

    def write_production(self, root: Path, path_segments: list[str]) -> Path:
        root.mkdir(parents=True, exist_ok=True)
        path = root / "production.json"
        path.write_text(json.dumps({
            "schemaVersion": 9999,
            "producerOnly": {"ignored": True},
            "productionId": self.production_id,
            "episodes": [{
                "id": self.episode_id,
                "pathSegments": path_segments,
                "producerMetadata": "ignored",
            }],
        }), encoding="utf-8")
        return path

    def test_preserves_every_collection_and_adds_authoritative_episode_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v27.json", root / "Scenes.v28.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            production = self.write_production(
                root / "catalog", ["shows", "season-one", "episode-one"]
            )

            backup = MIGRATION.migrate(source, destination, [production])
            result = json.loads(destination.read_text())

            expected = copy.deepcopy(fixture)
            expected["schemaVersion"] = 28
            expected["productions"][0]["episodes"][0]["externalReference"][
                "episodePathSegments"
            ] = ["shows", "season-one", "episode-one"]
            self.assertEqual(result, expected)
            self.assertEqual(backup.read_bytes(), original)

    def test_rejects_missing_or_unsafe_authoritative_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Scenes.v27.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            missing_episode = self.write_production(root / "missing", ["safe"])
            document = json.loads(missing_episode.read_text())
            document["episodes"] = []
            missing_episode.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(ValueError):
                MIGRATION.migrated_document(source, [missing_episode])

            unsafe = self.write_production(root / "unsafe", ["safe", "..", "escape"])
            with self.assertRaises(ValueError):
                MIGRATION.migrated_document(source, [unsafe])

    def test_refuses_existing_destination_before_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Scenes.v27.json", root / "Scenes.v28.json"
            source.write_text(json.dumps(self.fixture()), encoding="utf-8")
            destination.write_text("occupied", encoding="utf-8")
            production = self.write_production(root / "catalog", ["safe"])
            with self.assertRaises(FileExistsError):
                MIGRATION.migrate(source, destination, [production])
            self.assertEqual(list(root.glob("*.backup-*")), [])


if __name__ == "__main__":
    unittest.main()
