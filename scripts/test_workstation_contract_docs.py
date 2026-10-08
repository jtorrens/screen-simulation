import unittest
from pathlib import Path

from check_decision_authority import DecisionAuthorityError
from check_workstation_contract_docs import current_versions, validate, validate_text


class WorkstationContractDocsTests(unittest.TestCase):
    def test_repository_documents_match_current_source_contracts(self):
        validate(Path(__file__).resolve().parents[1])

    def test_each_retired_or_future_named_contract_is_rejected(self):
        versions = current_versions(Path(__file__).resolve().parents[1])
        for family, current in versions.items():
            for version in (current - 1, current + 1):
                with self.subTest(family=family, version=version):
                    with self.assertRaises(DecisionAuthorityError):
                        validate_text(f"Current `{family}.v{version}`", versions, "fixture")

    def test_prose_spellings_and_retired_migration_ledgers_are_rejected(self):
        versions = {"SavedScene": 29, "RenderQueue": 18}
        for text in ("Saved Scene v24", "Queue v17", "v24-to-v25", "v24→v25"):
            with self.subTest(text=text), self.assertRaises(DecisionAuthorityError):
                validate_text(text, versions, "fixture")

    def test_unrelated_scoped_versions_are_not_reinterpreted(self):
        validate_text("Portable schema 23, Fusion metadata schema-v5 and RAW-v1",
                      {"SavedScene": 29}, "fixture")


if __name__ == "__main__":
    unittest.main()
