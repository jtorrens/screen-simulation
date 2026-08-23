#!/usr/bin/env python3
import copy
import json
import pathlib
import tempfile
import unittest

from migrate_global_library_v16_to_v17 import (
    DEFAULT_LENS_EVALUATION_MODEL_ID,
    ROOT_KEYS,
    migrate,
)


class GlobalLibraryCameraDefaultMigrationTests(unittest.TestCase):
    def test_changes_only_camera_default_and_preserves_every_user_item(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "v16.json"
            output = root / "v17.json"
            document = {
                key: [{"value": {"id": f"user-{key}", "name": f"User {key}"}, "isLocked": False}]
                for key in ROOT_KEYS if key not in {"schemaVersion", "cameras"}
            }
            document["schemaVersion"] = 16
            document["cameras"] = [
                {
                    "value": {
                        "id": "user-camera-thin",
                        "name": "User Thin",
                        "defaultLensEvaluationModelID": "thin-lens",
                        "authoredMarker": 17,
                    },
                    "isLocked": False,
                },
                {
                    "value": {
                        "id": "locked-camera-vfx",
                        "name": "Locked VFX",
                        "defaultLensEvaluationModelID": "vfx-2d-dof",
                        "authoredMarker": 29,
                    },
                    "isLocked": True,
                },
            ]
            before_document = copy.deepcopy(document)
            source.write_text(json.dumps(document), encoding="utf-8")
            before_bytes = source.read_bytes()

            backup = migrate(source, output)
            result = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual(result["schemaVersion"], 17)
            for collection in ROOT_KEYS - {"schemaVersion", "cameras"}:
                self.assertEqual(result[collection], before_document[collection])
            self.assertEqual(
                [item["value"]["id"] for item in result["cameras"]],
                [item["value"]["id"] for item in before_document["cameras"]],
            )
            self.assertEqual(
                [item["isLocked"] for item in result["cameras"]],
                [item["isLocked"] for item in before_document["cameras"]],
            )
            for migrated, original in zip(result["cameras"], before_document["cameras"]):
                self.assertEqual(
                    migrated["value"]["defaultLensEvaluationModelID"],
                    DEFAULT_LENS_EVALUATION_MODEL_ID,
                )
                migrated_value = dict(migrated["value"])
                original_value = dict(original["value"])
                migrated_value.pop("defaultLensEvaluationModelID")
                original_value.pop("defaultLensEvaluationModelID")
                self.assertEqual(migrated_value, original_value)
            self.assertEqual(source.read_bytes(), before_bytes)
            self.assertEqual(backup.read_bytes(), before_bytes)


if __name__ == "__main__":
    unittest.main()
