#!/usr/bin/env python3
"""Review GitHub's paginated dependency comparison without broad LicenseRef exemptions."""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = ROOT / ".github/dependency-license-policy.json"
IDENTITY_FIELDS = ("manifest", "ecosystem", "name", "version", "license", "source_repository_url")


def review(pages, policy):
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise ValueError("Expected the paginated dependency comparison (--paginate --slurp)")
    allowed = set(policy["allowedLicenses"])
    reviewed = policy["reviewedPackages"]
    for package in reviewed:
        if not package["licenses"] or not set(package["licenses"]) <= allowed:
            raise ValueError("A reviewed package must use only existing policy-approved licenses")
        if not all(isinstance(package.get(key), str) and package[key] for key in IDENTITY_FIELDS):
            raise ValueError("Reviewed package identity must be exact, including version and source")
    rejected, unresolved, normalized = set(), set(), set()
    for page in pages:
        for change in page:
            if not isinstance(change, dict) or change.get("change_type") not in ("added", "removed"):
                raise ValueError("Malformed dependency change or unsupported change_type")
            if change["change_type"] == "removed":
                continue
            if not all(isinstance(change.get(key), str) and change[key]
                       for key in ("manifest", "ecosystem", "name", "version")):
                raise ValueError("Dependency identity is missing from the comparison")
            label = f'{change["manifest"]} » {change["name"]}@{change["version"]}'
            license_id = change.get("license")
            if license_id is None or (isinstance(license_id, str) and license_id.lower() == "noassertion"):
                unresolved.add(label)
            elif not isinstance(license_id, str) or not license_id:
                raise ValueError(f"Malformed license for {label}")
            elif license_id.lower() in allowed:
                continue
            else:
                match = next((package for package in reviewed if all(
                    change.get(key) == package[key] for key in IDENTITY_FIELDS
                )), None)
                if match is None:
                    rejected.add(f"{label} – License: {license_id}")
                else:
                    normalized.add(f'{label} – reviewed notices: {" AND ".join(match["licenses"])}')
    return sorted(rejected), sorted(unresolved), sorted(normalized)


def main():
    try:
        policy = json.loads(POLICY_PATH.read_text())
        rejected, unresolved, normalized = review(json.load(sys.stdin), policy)
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Cannot review dependency licenses: {error}", file=sys.stderr)
        return 1
    if normalized:
        print("Exact package license notices reviewed under the existing policy:")
        print("\n".join(normalized))
    if unresolved:
        # Preserve the existing unresolved-metadata warning. Unknown SPDX/LicenseRef values are
        # NOT unresolved: they still fail unless this exact published package was reviewed.
        print("::warning::GitHub could not resolve licenses for some dependency changes; review the dependency summary.")
        print("\n".join(unresolved))
    if rejected:
        print("Dependencies outside the reviewed license policy:", file=sys.stderr)
        print("\n".join(rejected), file=sys.stderr)
        return 1
    print("Dependency license review passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
