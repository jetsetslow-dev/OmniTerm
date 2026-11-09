#!/usr/bin/env python3
"""Fails on a Go module whose licence the pull request's Dependency review would reject, before a push.

Dependency review (.github/workflows/dependency-review.yml) accepts only the licences in its
`allow-licenses` list, and GitHub's dependency graph sees the Go modules that tunnel/go.mod
requires. This reads that same list, finds each required module's licence files (LICENSE, COPYING,
PATENTS, ...) in the module cache, and names the licences they hold. A module with a licence outside
the list, or with a licence file this script cannot name, fails: the second needs a person to read
it, which is better done before a push than after Dependency review flags it (as PATENTS did on
PR #147).

Run with the repository's Go toolchain on PATH:
  (eval "$(./scripts/go-toolchain.sh)" && python3 ./scripts/check-licenses.py)

Usage: check-licenses.py [--workflow .github/workflows/dependency-review.yml] [--module tunnel]
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|patents)([-._].*)?$", re.IGNORECASE)

# Each licence a file can hold, by phrases its text always carries (compared after lowercasing and
# turning every run of punctuation and space into one space). A file may hold several.
SIGNATURES = [
    ("Apache-2.0", ["apache license version 2 0"]),
    ("MIT", ["permission is hereby granted free of charge to any person obtaining a copy"]),
    ("ISC", ["permission to use copy modify and or distribute this software for any purpose"]),
    ("MPL-2.0", ["mozilla public license version 2 0"]),
    ("BSD-3-Clause", ["redistribution and use in source and binary forms",
                      "may be used to endorse or promote products derived from this software"]),
    ("BSD-2-Clause", ["redistribution and use in source and binary forms"]),
    # Google's extra patent grant beside the BSD-3-Clause licence of the Go project's libraries.
    ("LicenseRef-scancode-google-patent-license-golang",
     ["additional ip rights grant patents", "implementation of go"]),
    # Never allowed, but named so the failure says what was found.
    ("AGPL", ["gnu affero general public license"]),
    ("LGPL", ["gnu lesser general public license"]),
    ("GPL", ["gnu general public license"]),
    ("BUSL-1.1", ["business source license"]),
    ("SSPL-1.0", ["server side public license"]),
]
# A licence whose phrases include another's: the wider one is named alone.
WIDER = {"BSD-3-Clause": "BSD-2-Clause", "AGPL": "GPL", "LGPL": "GPL"}


def normalise(text):
    return " ".join(re.sub(r"[^a-z0-9]+", " ", text.lower()).split())


def licences_in(text):
    """The licences [text] holds, by SIGNATURES; empty when it matches none."""
    plain = normalise(text)
    found = {name for name, phrases in SIGNATURES if all(p in plain for p in phrases)}
    return found - {WIDER[n] for n in found if n in WIDER}


def allowed_licences(workflow):
    """The `allow-licenses` list of the dependency-review step in [workflow]."""
    lines = pathlib.Path(workflow).read_text().splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)allow-licenses:\s*(.*)$", line)
        if not m:
            continue
        indent, value = len(m.group(1)), m.group(2).strip()
        if value and value not in (">-", ">", "|", "|-"):
            items = value
        else:
            block = []
            for follow in lines[i + 1:]:
                if follow.strip() and len(follow) - len(follow.lstrip()) <= indent:
                    break
                if not follow.strip().startswith("#"):
                    block.append(follow.strip())
            items = " ".join(block)
        return {item.strip() for item in items.split(",") if item.strip()}
    sys.exit(f"check-licenses: no allow-licenses in {workflow}")


def problems(modules, allowed):
    """(module, message) for each module in [modules] ((name, directory) pairs) Dependency review
    would reject or this script cannot read."""
    found = []
    for name, directory in modules:
        files = sorted(p for p in pathlib.Path(directory).iterdir() if p.is_file() and LICENCE_FILE.match(p.name))
        if not files:
            found.append((name, "has no licence file"))
        for f in files:
            names = licences_in(f.read_text(errors="replace"))
            if not names:
                found.append((name, f"{f.name} holds a licence this script cannot name; read it and add it to SIGNATURES"))
            for licence in sorted(names - allowed):
                found.append((name, f"{f.name} is {licence}, which allow-licenses does not list"))
    return found


def go(*args, cwd):
    result = subprocess.run(["go", *args], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"check-licenses: go {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout


def required_modules(module):
    """(name@version, directory) for each module [module]'s go.mod requires, downloaded if missing
    and checked against go.sum on the way."""
    if not shutil.which("go"):
        sys.exit('check-licenses: no go on PATH; run it as (eval "$(./scripts/go-toolchain.sh)" && ...)')
    required = [f'{r["Path"]}@{r["Version"]}' for r in json.loads(go("mod", "edit", "-json", cwd=module))["Require"]]
    # go mod download -json prints one JSON object after another, not a list.
    text, at, decoder, modules = go("mod", "download", "-json", *required, cwd=module), 0, json.JSONDecoder(), []
    while text[at:].strip():
        info, at = decoder.raw_decode(text, at + len(text[at:]) - len(text[at:].lstrip()))
        if "Error" in info or "Dir" not in info:
            sys.exit(f'check-licenses: {info["Path"]}@{info["Version"]}: {info.get("Error", "not downloaded")}')
        modules.append((f'{info["Path"]}@{info["Version"]}', info["Dir"]))
    if len(modules) != len(required):
        sys.exit(f"check-licenses: go.mod requires {len(required)} modules, but {len(modules)} were found")
    return modules


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflow", default=ROOT / ".github/workflows/dependency-review.yml")
    parser.add_argument("--module", default=ROOT / "tunnel")
    args = parser.parse_args()

    allowed = allowed_licences(args.workflow)
    modules = required_modules(args.module)
    found = problems(modules, allowed)
    for name, message in found:
        print(f"{name}: {message}")
    if found:
        sys.exit(f"Licences: {len(found)} problem(s) in {len(modules)} Go modules; Dependency review would fail.")
    print(f"Licences: {len(modules)} Go modules, all under dependency-review.yml's allow-licenses.")


if __name__ == "__main__":
    main()
