#!/usr/bin/env python3
"""Offline regression tests for the same license reviewer used by required CI."""

import copy
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("license_review", ROOT / "scripts/check-dependency-licenses.py")
REVIEWER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REVIEWER)
POLICY = json.loads(REVIEWER.POLICY_PATH.read_text())


class DependencyLicensePolicyTest(unittest.TestCase):
    def setUp(self):
        self.package = {key: POLICY["reviewedPackages"][0][key] for key in REVIEWER.IDENTITY_FIELDS}
        self.package["change_type"] = "added"

    def review(self, *changes, policy=None):
        return REVIEWER.review([list(changes)], POLICY if policy is None else policy)

    def test_standard_licenses_preserve_case_insensitive_policy(self):
        for license_id in POLICY["allowedLicenses"]:
            with self.subTest(license=license_id):
                self.assertEqual(([], [], []), self.review({**self.package, "license": license_id.upper()}))

    def test_reviewed_package_is_reported_not_silently_ignored(self):
        rejected, unresolved, normalized = self.review(self.package)
        self.assertEqual([], rejected)
        self.assertEqual([], unresolved)
        self.assertEqual(1, len(normalized))
        self.assertIn("bsd-3-clause AND apache-2.0", normalized[0])

    def test_no_identity_field_can_borrow_a_review(self):
        for key in REVIEWER.IDENTITY_FIELDS:
            with self.subTest(field=key):
                rejected, _, normalized = self.review({**self.package, key: self.package[key] + "-different"})
                self.assertEqual(1, len(rejected))
                self.assertEqual([], normalized)

    def test_other_license_refs_and_unreviewed_compounds_still_fail(self):
        for license_id in ("LicenseRef-custom", "GPL-3.0-only", "MIT OR GPL-3.0-only", "MIT AND Apache-2.0"):
            with self.subTest(license=license_id):
                self.assertEqual(1, len(self.review({**self.package, "license": license_id})[0]))

    def test_unresolved_metadata_remains_a_visible_warning(self):
        for license_id in (None, "NOASSERTION", "noassertion"):
            self.assertEqual(1, len(self.review({**self.package, "license": license_id})[1]))

    def test_removing_a_dependency_does_not_require_a_new_license_review(self):
        self.assertEqual(([], [], []), self.review({**self.package, "change_type": "removed", "license": "GPL-3.0-only"}))

    def test_paginated_results_are_all_reviewed_and_deduplicated(self):
        bad = {**self.package, "name": "unreviewed"}
        rejected, _, normalized = REVIEWER.review([[self.package], [bad, bad]], POLICY)
        self.assertEqual(1, len(rejected))
        self.assertEqual(1, len(normalized))

    def test_malformed_api_responses_fail_closed(self):
        for payload in ({"error": "denied"}, [self.package], [[None]], [[{}]], [[{**self.package, "license": []}]],
                        [[{**self.package, "change_type": "unexpected"}]], [[{**self.package, "version": None}]]):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                REVIEWER.review(payload, POLICY)

    def test_normalization_cannot_add_a_disallowed_license(self):
        policy = copy.deepcopy(POLICY)
        policy["reviewedPackages"][0]["licenses"].append("GPL-3.0-only")
        with self.assertRaises(ValueError):
            self.review(self.package, policy=policy)

    def test_review_provenance_matches_the_locked_archive(self):
        lock = (ROOT / "flutter_app/pubspec.lock").read_text()
        for package in POLICY["reviewedPackages"]:
            name = re.escape(package["name"])
            block = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  \S|\Z)", lock).group(1)
            self.assertIn(f'version: "{package["version"]}"', block)
            self.assertIn(package["archiveSha256"], block)
            self.assertRegex(package["licenseSha256"], r"^[a-f0-9]{64}$")

    def test_local_native_ci_and_dependency_ci_execute_the_same_tests(self):
        command = "python3 scripts/test-dependency-license-policy.py"
        for path in ("scripts/local-pr-check.sh", ".github/workflows/android-pr-check.yml",
                     ".github/workflows/dependency-review.yml"):
            self.assertIn(command, (ROOT / path).read_text())
        workflow = (ROOT / ".github/workflows/dependency-review.yml").read_text()
        self.assertIn("python3 scripts/check-dependency-licenses.py", workflow)
        self.assertIn("fail-on-severity: moderate", workflow)


if __name__ == "__main__":
    unittest.main()
