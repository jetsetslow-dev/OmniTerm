#!/usr/bin/env python3
"""Fails when hand-written code gains a new copy-pasted block.

A clone is a run of at least --min-tokens identical tokens (comments, imports and the package line
left out) found twice, in one file or two. Known clones are listed in a baseline by a fingerprint of
their tokens, not by line numbers, so editing around a known clone does not trip the check, while
copying a block somewhere new does. Fix a new clone by extracting the shared code; only
--update-baseline accepts one, and the baseline is reviewed like any other change.

Usage:
  check-duplicates.py --baseline FILE [--update-baseline] [--min-tokens N] [--exclude GLOB]... PATH...
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

EXTENSIONS = {".kt", ".kts", ".dart"}

TOKEN = re.compile(
    r'"""(?:.|\n)*?"""'            # Kotlin raw string
    r"|'''(?:.|\n)*?'''"           # Dart multi-line string
    r'|"(?:\\.|[^"\\\n])*"'        # double-quoted string
    r"|'(?:\\.|[^'\\\n])*'"        # single-quoted string or char
    r"|[A-Za-z_$][A-Za-z0-9_$]*"   # identifier or keyword
    r"|\d[\d_]*(?:\.\d+)?[A-Za-z]*"  # number
    r"|\S"                         # any other single character
)
COMMENT = re.compile(r"//[^\n]*|/\*(?:.|\n)*?\*/")
SKIPPED_LINE = re.compile(r"^\s*(?:import|package|export|part|library)\b[^\n]*$", re.MULTILINE)


def tokens(text: str) -> list[tuple[str, int]]:
    """(token, line) pairs with comments and import/package lines blanked out, lines kept."""
    blank = lambda m: re.sub(r"[^\n]", " ", m.group(0))
    text = SKIPPED_LINE.sub(blank, COMMENT.sub(blank, text))
    out = []
    line = 1
    last = 0
    for m in TOKEN.finditer(text):
        line += text.count("\n", last, m.start())
        last = m.start()
        out.append((m.group(0), line))
    return out


def sources(paths: list[str], excludes: list[str]) -> list[Path]:
    found = []
    for p in paths:
        root = Path(p)
        candidates = [root] if root.is_file() else sorted(root.rglob("*"))
        for f in candidates:
            if f.suffix in EXTENSIONS and f.is_file() and not any(fnmatch.fnmatch(str(f), g) for g in excludes):
                found.append(f)
    return found


def clones(files: list[Path], min_tokens: int) -> list[dict]:
    toks = [tokens(f.read_text(encoding="utf-8", errors="replace")) for f in files]
    windows: dict[int, list[tuple[int, int]]] = defaultdict(list)
    for fi, ts in enumerate(toks):
        texts = [t for t, _ in ts]
        for pos in range(len(texts) - min_tokens + 1):
            windows[hash(tuple(texts[pos:pos + min_tokens]))].append((fi, pos))

    # Matching windows at a constant offset between two places form one clone.
    runs: dict[tuple[int, int, int], list[int]] = defaultdict(list)
    for places in windows.values():
        if len(places) < 2:
            continue
        places = places[:12]  # a pattern repeated dozens of times is reported by its first few
        for i, (fa, pa) in enumerate(places):
            for fb, pb in places[i + 1:]:
                if fa == fb and pb - pa < min_tokens:
                    continue
                runs[(fa, fb, pb - pa)].append(pa)

    found = []
    for (fa, fb, offset), starts in runs.items():
        starts.sort()
        begin = prev = starts[0]
        for s in starts[1:] + [None]:
            if s is not None and s == prev + 1:
                prev = s
                continue
            end = prev + min_tokens
            block = [t for t, _ in toks[fa][begin:end]]
            found.append({
                "fingerprint": hashlib.sha1("\x00".join(block).encode()).hexdigest()[:16],
                "tokens": end - begin,
                "first": f"{files[fa]}:{toks[fa][begin][1]}-{toks[fa][end - 1][1]}",
                "second": f"{files[fb]}:{toks[fb][begin + offset][1]}-{toks[fb][end - 1 + offset][1]}",
            })
            if s is not None:
                begin = prev = s
    # One block found from several pairs of its copies, or nested in a longer one, is reported
    # once, with the number of places it appears.
    found.sort(key=lambda c: -c["tokens"])
    places: dict[str, set[str]] = defaultdict(set)
    for c in found:
        places[c["fingerprint"]].update((c["first"], c["second"]))
    seen: set[str] = set()
    unique = []
    for c in found:
        if c["fingerprint"] not in seen:
            seen.add(c["fingerprint"])
            unique.append({**c, "copies": len(places[c["fingerprint"]])})
    return unique


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--min-tokens", type=int, default=70)
    parser.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args()

    found = clones(sources(args.paths, args.exclude), args.min_tokens)
    baseline_path = Path(args.baseline)
    if args.update_baseline:
        baseline_path.write_text(json.dumps(
            {"minTokens": args.min_tokens, "clones": sorted(found, key=lambda c: c["first"])}, indent=2) + "\n")
        print(f"Baseline: {len(found)} known clone(s) written to {baseline_path}")
        return 0

    known = {c["fingerprint"]: c.get("copies", 2)
             for c in json.loads(baseline_path.read_text())["clones"]} if baseline_path.exists() else {}
    # A known block copied once more is as new as a fresh one.
    new = [c for c in found if c["copies"] > known.get(c["fingerprint"], 0)]
    gone = len(set(known) - {c["fingerprint"] for c in found})
    for c in new:
        print(f"New duplicated block ({c['tokens']} tokens, {c['copies']} copies): {c['first']} and {c['second']}")
    if new:
        print(f"{len(new)} new duplicated block(s). Extract the shared code; see {Path(__file__).name}.")
        return 1
    print(f"No new duplicated blocks ({len(found)} known" + (f"; {gone} fixed, run --update-baseline" if gone else "") + ").")
    return 0


if __name__ == "__main__":
    sys.exit(main())
