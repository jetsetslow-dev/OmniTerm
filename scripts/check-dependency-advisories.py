#!/usr/bin/env python3
"""Fails on a dependency with a known vulnerability, before a push rather than on the pull request.

Dependabot alerts and the pull request's Dependency review (fail-on-severity: moderate) both read
GitHub's advisory database. This asks the same database, through `gh api`, about the same
dependencies: the release runtime classpaths that dependency-submission.yml reports (as CycloneDX
SBOMs) and the pinned GitHub Actions. main has no open Dependabot alerts, so any moderate or worse
advisory fails.

Usage: check-dependency-advisories.py [--cyclonedx bom.json]... [--actions .github]
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

FAILING = {"medium", "high", "critical"}
BATCH = 40


def cyclonedx(path):
    for c in json.loads(pathlib.Path(path).read_text()).get("components", []):
        # The project's own modules appear too, as unversioned components with a project path.
        if c.get("purl", "").startswith("pkg:maven/") and "project_path=" not in c["purl"]:
            yield f'{c["group"]}:{c["name"]}', c["version"]


def actions(root):
    pinned = re.compile(r"uses:\s*([\w.-]+/[\w.-]+)(?:/[^@\s]*)?@[0-9a-f]{40}\s*#\s*v?([\w.-]+)")
    for path in pathlib.Path(root).rglob("*.y*ml"):
        for m in pinned.finditer(path.read_text()):
            yield m.group(1), m.group(2)


def advisories(ecosystem, packages):
    """Advisories affecting any of [packages] (name, version) at those versions."""
    # The answer names the affected package but not which of its versions matched, so a request
    # holds at most one version of each package: rounds of first versions, second versions, ...
    by_name = {}
    for name, version in packages:
        by_name.setdefault(name, []).append(version)
    rounds = [
        [(name, versions[k]) for name, versions in by_name.items() if k < len(versions)]
        for k in range(max(map(len, by_name.values()), default=0))
    ]
    batches = [r[i:i + BATCH] for r in rounds for i in range(0, len(r), BATCH)]
    found = {}
    for batch in batches:
        result = subprocess.run(
            ["gh", "api", "-X", "GET", "/advisories", "--paginate",
             "-f", f"ecosystem={ecosystem}", "-f", "per_page=100",
             "-f", "affects=" + ",".join(f"{n}@{v}" for n, v in batch),
             "--jq", ".[] | {ghsa_id, severity, summary, withdrawn_at, vulnerabilities}"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            sys.exit(f"Could not query GitHub's advisory database: {result.stderr.strip()}")
        for line in result.stdout.splitlines():
            advisory = json.loads(line)
            if advisory["withdrawn_at"] or advisory["severity"] not in FAILING:
                continue
            affected = {v["package"]["name"] for v in advisory["vulnerabilities"] or []}
            for name, version in batch:
                if name in affected:
                    found.setdefault((name, version), {})[advisory["ghsa_id"]] = advisory
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cyclonedx", action="append", default=[])
    parser.add_argument("--actions")
    args = parser.parse_args()

    inputs = {
        "maven": sorted({p for f in args.cyclonedx for p in cyclonedx(f)}),
        "actions": sorted(set(actions(args.actions))) if args.actions else [],
    }
    hits = {}
    for ecosystem, packages in inputs.items():
        if packages:
            hits.update(advisories(ecosystem, packages))
    checked = ", ".join(f"{len(p)} {e}" for e, p in inputs.items() if p)
    if not checked:
        sys.exit("No dependencies found to check.")
    for (name, version), found in sorted(hits.items()):
        for ghsa, a in found.items():
            print(f"{name}@{version}: {ghsa} ({a['severity']}) {a['summary']}")
    if hits:
        noun = "dependency" if len(hits) == 1 else "dependencies"
        sys.exit(f"Dependency advisories: {len(hits)} vulnerable {noun} ({checked} checked).")
    print(f"Dependency advisories: none at moderate or above ({checked} checked).")


if __name__ == "__main__":
    main()
