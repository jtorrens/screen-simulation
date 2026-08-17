#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_global_library_v9_to_v10.py")
SPEC = importlib.util.spec_from_file_location("global_migration_v10", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class GlobalLibraryMigrationTests(unittest.TestCase):
    def test_replaces_retired_glow_shape_without_mutating_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Global.v9.json", root / "Global.v10.json"
            original = {
                "schemaVersion": 9, "patterns": [], "testImages": [], "renderPresets": [],
                "devices": [], "coverGlasses": [{"isLocked": True, "value": {
                    "glowScatterFraction": .12, "glowCoreRadiusMillimeters": .4,
                    "glowTailRadiusMillimeters": 3.5, "glowTailFraction": .5,
                }}],
            }
            source.write_text(json.dumps(original), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 10)
            cover = result["coverGlasses"][0]["value"]
            self.assertEqual(cover["glowIntensity"], .12)
            self.assertEqual(cover["glowRadiusMillimeters"], 3.5)
            self.assertTrue(OLD_KEYS.isdisjoint(cover))


OLD_KEYS = {
    "glowScatterFraction", "glowCoreRadiusMillimeters",
    "glowTailRadiusMillimeters", "glowTailFraction",
}


if __name__ == "__main__":
    unittest.main()
