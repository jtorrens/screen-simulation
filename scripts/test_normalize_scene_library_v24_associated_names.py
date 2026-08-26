#!/usr/bin/env python3

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("normalize_scene_library_v24_associated_names.py")
SPEC = importlib.util.spec_from_file_location("scene_associated_name_normalization", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class SceneLibraryAssociatedNameNormalizationTests(unittest.TestCase):
    def fixture(self) -> dict:
        return {
            "schemaVersion": 24,
            "scenes": [
                {"id": "00000000-0000-0000-0000-000000000001", "name": "Manual", "snapshot": {"authored": 1}},
                {"id": "00000000-0000-0000-0000-000000000002", "name": "Libre", "snapshot": {"authored": 2}},
            ],
            "productions": [{
                "id": "10000000-0000-0000-0000-000000000001", "name": "Producción",
                "episodes": [{
                    "id": "20000000-0000-0000-0000-000000000001", "name": "Episodio manual",
                    "associationState": "associated",
                    "externalReference": {"episodeSlug": "EP01", "kept": True},
                    "shots": [{
                        "id": "30000000-0000-0000-0000-000000000001", "name": "Plano manual",
                        "associationState": "associated",
                        "externalReference": {"canonicalName": "SH010", "kept": True},
                        "scenes": [{"sceneID": "00000000-0000-0000-0000-000000000001", "ordinal": 7}],
                        "nextSceneOrdinal": 9,
                    }],
                }],
            }],
            "unclassifiedSceneIDs": ["00000000-0000-0000-0000-000000000002"],
        }

    def test_changes_only_derived_names_and_creates_exact_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v24.json"
            fixture = self.fixture()
            source.write_text(json.dumps(fixture, separators=(",", ":")), encoding="utf-8")
            original = source.read_bytes()
            backup = MIGRATION.migrate(source)
            result = json.loads(source.read_text())

            self.assertEqual(backup.read_bytes(), original)
            self.assertEqual(result["productions"][0]["episodes"][0]["name"], "EP01")
            shot = result["productions"][0]["episodes"][0]["shots"][0]
            self.assertEqual(shot["name"], "SH010")
            self.assertEqual(result["scenes"][0]["name"], "SH010_007")
            self.assertEqual(result["scenes"][1], fixture["scenes"][1])
            self.assertEqual(shot["scenes"], fixture["productions"][0]["episodes"][0]["shots"][0]["scenes"])
            self.assertEqual(shot["nextSceneOrdinal"], 9)
            self.assertEqual(result["unclassifiedSceneIDs"], fixture["unclassifiedSceneIDs"])
            expected = copy.deepcopy(fixture)
            expected["productions"][0]["episodes"][0]["name"] = "EP01"
            expected["productions"][0]["episodes"][0]["shots"][0]["name"] = "SH010"
            expected["scenes"][0]["name"] = "SH010_007"
            self.assertEqual(result, expected)

    def test_rejects_missing_associated_name_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v24.json"
            fixture = self.fixture()
            fixture["productions"][0]["episodes"][0]["externalReference"]["episodeSlug"] = ""
            source.write_text(json.dumps(fixture), encoding="utf-8")
            original = source.read_bytes()
            with self.assertRaises(ValueError):
                MIGRATION.migrate(source)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(list(Path(temporary).glob("*.backup-*")), [])

    def test_rejects_unknown_scene_placement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Scenes.v24.json"
            fixture = self.fixture()
            fixture["productions"][0]["episodes"][0]["shots"][0]["scenes"][0]["sceneID"] = (
                "ffffffff-ffff-ffff-ffff-ffffffffffff"
            )
            source.write_text(json.dumps(fixture), encoding="utf-8")
            with self.assertRaises(ValueError):
                MIGRATION.normalized_document(source)


if __name__ == "__main__":
    unittest.main()
