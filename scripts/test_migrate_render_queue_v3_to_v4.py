#!/usr/bin/env python3
import json
import pathlib
import tempfile
import unittest
from migrate_render_queue_v3_to_v4 import migrate


class RenderQueueMigrationTests(unittest.TestCase):
    def test_adds_explicit_origin_and_preserves_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "v3.json"
            output = root / "v4.json"
            document = {"schema": "ScreenSimulation.RenderQueue.v3", "isPaused": True, "jobs": [{"id": "a"}]}
            source.write_text(json.dumps(document), encoding="utf-8")
            before = source.read_bytes()
            backup = migrate(source, output)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["schema"], "ScreenSimulation.RenderQueue.v4")
            self.assertIsNone(result["jobs"][0]["derivedFromJobID"])
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(backup.read_bytes(), before)
            self.assertEqual(
                list(root.glob("v3.backup-*.json")), [backup]
            )


if __name__ == "__main__":
    unittest.main()
