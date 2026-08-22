#!/usr/bin/env python3
import json
import pathlib
import tempfile
import unittest

from migrate_render_queue_v4_to_v5 import migrate


class RenderQueueV5MigrationTests(unittest.TestCase):
    def test_makes_only_wip_jobs_opaque_and_preserves_verified_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "RenderQueue.v4.json"
            output = root / "RenderQueue.v5.json"
            document = {
                "schema": "ScreenSimulation.RenderQueue.v4",
                "isPaused": False,
                "jobs": [
                    {"configuration": {"alpha": "straight", "wipReview": {"id": "wip"}}},
                    {"configuration": {"alpha": "premultiplied"}},
                ],
            }
            source.write_text(json.dumps(document), encoding="utf-8")
            before = source.read_bytes()
            backup = migrate(source, output)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["schema"], "ScreenSimulation.RenderQueue.v5")
            self.assertEqual(result["jobs"][0]["configuration"]["alpha"], "ignore")
            self.assertEqual(result["jobs"][1]["configuration"]["alpha"], "premultiplied")
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(backup.read_bytes(), before)
            self.assertEqual(list(root.glob("RenderQueue.v4.backup-*.json")), [backup])

    def test_rejects_missing_required_alpha(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "RenderQueue.v4.json"
            source.write_text(json.dumps({
                "schema": "ScreenSimulation.RenderQueue.v4",
                "isPaused": False,
                "jobs": [{"configuration": {"wipReview": {"id": "wip"}}}],
            }), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "alpha"):
                migrate(source, root / "RenderQueue.v5.json")


if __name__ == "__main__":
    unittest.main()
