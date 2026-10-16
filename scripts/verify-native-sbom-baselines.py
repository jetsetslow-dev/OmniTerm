#!/usr/bin/env python3
"""Check resolved release artifacts against the reviewed version catalog (Python 3.11+)."""

import argparse
import json
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    raise SystemExit("Release dependency validation requires Python 3.11 or newer.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sbom", type=Path)
    parser.add_argument(
        "--configuration",
        required=True,
        choices=("openSourceReleaseRuntimeClasspath", "playStoreReleaseRuntimeClasspath", "releaseRuntimeClasspath"),
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    versions = tomllib.loads((root / "gradle/libs.versions.toml").read_text())["versions"]
    components = json.loads(args.sbom.read_text())["components"]
    resolved: dict[tuple[str, str], set[str]] = {}
    for component in components:
        key = (component.get("group", ""), component.get("name", ""))
        resolved.setdefault(key, set()).add(component.get("version", ""))

    expected = {("org.bouncycastle", "bcprov-jdk18on"): versions["bcprov"]}
    for sibling in ("bcpkix-jdk18on", "bcutil-jdk18on"):
        key = ("org.bouncycastle", sibling)
        if key in resolved:
            expected[key] = versions["bcprov"]
    guava = ("com.google.guava", "guava")
    # Guava is a version constraint, not an unconditional app dependency. Require the reviewed
    # version whenever a transitive dependency actually brings it into the packaged graph.
    if guava in resolved:
        expected[guava] = versions["guavaAndroid"]

    mismatches = []
    for (group, name), version in expected.items():
        actual = resolved.get((group, name), set())
        if actual != {version}:
            mismatches.append(
                f"{group}:{name}: catalog requires {version}, "
                f"release resolves {', '.join(sorted(actual)) or 'nothing'}"
            )
    if mismatches:
        raise SystemExit("Release dependency baseline mismatch:\n" + "\n".join(mismatches))
    summary = ", ".join(f"{group}:{name}:{version}" for (group, name), version in expected.items())
    print(f"Resolved release dependency baselines match the catalog: {args.configuration}: {summary}")


if __name__ == "__main__":
    main()
