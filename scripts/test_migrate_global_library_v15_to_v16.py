#!/usr/bin/env python3
import json
import pathlib
import tempfile
import unittest

from migrate_global_library_v15_to_v16 import PATTERN_ID, PRESET_ID, ROOT_KEYS, migrate


class GlobalLibraryVFXDeliveryMigrationTests(unittest.TestCase):
    def test_adds_locked_pattern_and_preset_and_preserves_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "v15.json"
            output = root / "v16.json"
            document = {
                key: [{"value": {"id": f"user-{key}", "name": f"User {key}"}, "isLocked": False}]
                for key in ROOT_KEYS if key != "schemaVersion"
            }
            document["schemaVersion"] = 15
            source.write_text(json.dumps(document), encoding="utf-8")
            before = source.read_bytes()

            backup = migrate(source, output)
            result = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual(result["schemaVersion"], 16)
            self.assertEqual(result["patterns"][-1]["value"]["id"], PATTERN_ID)
            self.assertEqual(result["patterns"][-1]["value"]["pattern"], 7)
            self.assertTrue(result["patterns"][-1]["isLocked"])
            self.assertEqual(result["renderPresets"][-1]["value"]["id"], PRESET_ID)
            self.assertEqual(result["renderPresets"][-1]["value"]["signalRange"], "full")
            self.assertEqual(result["renderPresets"][-1]["value"]["pixelEncoding"], "rgb44412")
            self.assertEqual(result["renderPresets"][-1]["value"]["alpha"], "straight")
            self.assertTrue(result["renderPresets"][-1]["isLocked"])
            for collection in ROOT_KEYS - {"schemaVersion", "patterns", "renderPresets"}:
                self.assertEqual(result[collection], document[collection])
            self.assertEqual(result["patterns"][:-1], document["patterns"])
            self.assertEqual(result["renderPresets"][:-1], document["renderPresets"])
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(backup.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
