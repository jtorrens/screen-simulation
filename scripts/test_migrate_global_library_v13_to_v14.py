#!/usr/bin/env python3

import importlib.util
import json
import math
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_global_library_v13_to_v14.py")
SPEC = importlib.util.spec_from_file_location("global_migration_v14", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class GlobalLibraryMigrationTests(unittest.TestCase):
    def fixture(self) -> dict:
        return {
            "schemaVersion": 13,
            "patterns": [], "testImages": [], "renderPresets": [],
            "devices": [], "coverGlasses": [], "cameras": [], "lenses": [],
            "environments": [{
                "isLocked": False,
                "value": {
                    "id": "custom-environment",
                    "environment": {
                        "placementAnchorDirectionWorld": [0.0, 0.0, 1.0],
                        "placementSourceDirection": [0.0, 0.0, 1.0],
                        "placementAngularScale": 2.0,
                        "placementRollDegrees": 30.0,
                    },
                },
            }],
        }

    def test_materializes_equivalent_mobius_transform_without_mutating_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "GlobalLibrary.v13.json"
            destination = root / "GlobalLibrary.v14.json"
            original = self.fixture()
            source.write_text(json.dumps(original), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 14)
            environment = result["environments"][0]["value"]["environment"]
            self.assertNotIn("placementAngularScale", environment)
            self.assertNotIn("placementRollDegrees", environment)
            transform = environment["placementTangentTransform"]
            self.assertAlmostEqual(transform[0], math.cos(math.radians(30)) / 2)
            self.assertAlmostEqual(transform[1], math.sin(math.radians(30)) / 2)
            self.assertEqual(transform[2:], [0.0, 0.0])

    def test_rejects_existing_v14_field_in_a_v13_document(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "GlobalLibrary.v13.json"
            document = self.fixture()
            document["environments"][0]["value"]["environment"][
                "placementTangentTransform"
            ] = [1.0, 0.0, 0.0, 0.0]
            source.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaises(ValueError):
                MIGRATION.migrated_document(source)


if __name__ == "__main__":
    unittest.main()
