#!/usr/bin/env python3
import json
import pathlib
import tempfile
import unittest
from migrate_global_library_v14_to_v15 import migrate


class GlobalLibraryMigrationTests(unittest.TestCase):
    def test_adds_locked_wip_family_and_preserves_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "v14.json"
            output = root / "v15.json"
            source.write_text(json.dumps({"schemaVersion": 14, "patterns": []}), encoding="utf-8")
            before = source.read_bytes()
            backup = migrate(source, output)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["schemaVersion"], 15)
            self.assertEqual(len(result["wipReviewPresets"]), 4)
            self.assertTrue(all(item["isLocked"] for item in result["wipReviewPresets"]))
            self.assertEqual(
                {zone["position"] for zone in result["wipReviewPresets"][0]["value"]["zones"]},
                {"topLeft", "topCenter", "topRight", "bottomLeft", "bottomCenter", "bottomRight"},
            )
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(backup.read_bytes(), before)
            self.assertEqual(
                list(root.glob("v14.backup-*.json")), [backup]
            )


if __name__ == "__main__":
    unittest.main()
