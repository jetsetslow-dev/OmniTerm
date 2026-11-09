#!/usr/bin/env python3
"""Fails when a Dockerfile's base image is not pinned by digest, before OpenSSF Scorecard says so.

Scorecard's Pinned-Dependencies check reads every file whose name contains "Dockerfile". It
reports `FROM image:tag` without `@sha256:` as an alert on the pull request, not as a failed check,
so it was only seen after the push (PR #147's WireGuard fixture). This applies the same rule here.
It also requires one digest per image and tag across the repository, so a refresh cannot leave
one fixture on an older build.

Usage: check-pinned-images.py [ROOT]   (default: the repository this script is in)
"""
import pathlib
import re
import subprocess
import sys

DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
# FROM [--platform=...] image [AS name]
FROM = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?\s*$", re.IGNORECASE)


def dockerfiles(root):
    listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True,
                            capture_output=True, text=True).stdout.split("\0")
    return sorted(root / path for path in listed if path and "dockerfile" in pathlib.PurePath(path).name.lower())


def problems(files, root):
    found, digests = [], {}
    for path in files:
        stages = set()
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = FROM.match(line)
            if not match:
                continue
            image, stage = match.group(1), match.group(2)
            where = f"{path.relative_to(root)}:{number}"
            if stage:
                stages.add(stage.lower())
            if image.lower() == "scratch" or image.lower() in stages:
                continue
            if not DIGEST.search(image):
                found.append(f"{where}: {image} is not pinned by digest; use {image}@sha256:<digest>")
                continue
            name, digest = image.split("@", 1)
            digests.setdefault(name, {}).setdefault(digest, []).append(where)
    for name, seen in sorted(digests.items()):
        if len(seen) > 1:
            places = "; ".join(f"{digest[7:19]}… at {', '.join(at)}" for digest, at in sorted(seen.items()))
            found.append(f"{name} is pinned to {len(seen)} different digests: {places}")
    return found


def main(argv):
    root = pathlib.Path(argv[1] if len(argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
    files = dockerfiles(root)
    found = problems(files, root)
    for problem in found:
        print(problem, file=sys.stderr)
    if found:
        return 1
    print(f"Base images: all pinned by digest in {len(files)} Dockerfile(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
