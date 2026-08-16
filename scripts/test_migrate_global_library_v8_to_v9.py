#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_global_library_v8_to_v9.py")
SPEC = importlib.util.spec_from_file_location("global_migration_v9", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MIGRATION)


class GlobalLibraryMigrationTests(unittest.TestCase):
    def test_materializes_builtin_threshold_without_mutating_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "Global.v8.json", root / "Global.v9.json"
            original = {
                "schemaVersion": 8, "patterns": [], "testImages": [], "renderPresets": [],
                "devices": [], "coverGlasses": [{
                    "isLocked": True, "value": {"id": "cover-glossy-strong-ar"},
                }],
            }
            source.write_text(json.dumps(original), encoding="utf-8")
            MIGRATION.migrate(source, destination)
            self.assertEqual(json.loads(source.read_text()), original)
            result = json.loads(destination.read_text())
            self.assertEqual(result["schemaVersion"], 9)
            self.assertEqual(result["coverGlasses"][0]["value"]["glowThresholdRelativeWhite"], .20)


if __name__ == "__main__":
    unittest.main()
