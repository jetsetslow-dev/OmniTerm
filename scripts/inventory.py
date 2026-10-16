#!/usr/bin/env python3
"""Build the exhaustive Kotlin UI inventory and cross-reference it against Flutter.

Enumerates the things a screen-by-screen audit has to cover -- composables, dialogs, long-press and
swipe handlers -- and marks each with whether Flutter appears to have a counterpart. The match is a
*heuristic* on names and copy; every row still needs reading. It exists to make the queue finite and
ordered, not to decide anything.
"""
import os, re, json, collections

KUI = "/home/sbvino/Omniterm/app/src/main/java/com/jetsetslow/omniterm/ui"
FLIB = "/home/sbvino/Omniterm/flutter_app/lib"

def read(p):
    return open(p, encoding="utf-8", errors="replace").read()

flutter = []
for root, _, files in os.walk(FLIB):
    for f in files:
        if f.endswith(".dart") and not f.endswith(".g.dart"):
            flutter.append(read(os.path.join(root, f)))
blob = "\n".join(flutter)
lower = blob.lower()

COMPOSABLE = re.compile(r"^(?:@Composable\s*\n)?fun ([A-Z]\w+)\s*\(", re.M)

rows = []
for name in sorted(os.listdir(KUI)):
    if not name.endswith(".kt"):
        continue
    path = os.path.join(KUI, name)
    text = read(path)
    lines = text.split("\n")

    for m in COMPOSABLE.finditer(text):
        fn = m.group(1)
        line = text[: m.start()].count("\n") + 1
        # crude name match: the Kotlin composable's words appearing together in Flutter
        words = re.findall(r"[A-Z][a-z]+", fn)
        stem = "".join(words).lower()
        present = stem in lower.replace("_", "") if stem else False
        rows.append(("composable", name, line, fn, present))

    for n, l in enumerate(lines, 1):
        if "AlertDialog(" in l:
            rows.append(("dialog", name, n, "AlertDialog", None))
        if "combinedClickable" in l or "onLongClick" in l:
            rows.append(("long-press", name, n, l.strip()[:60], None))
        if "detectHorizontalDragGestures" in l and "import" not in l:
            rows.append(("swipe", name, n, l.strip()[:60], None))

by_kind = collections.Counter(r[0] for r in rows)
by_file = collections.Counter(r[1] for r in rows)

print("KOTLIN UI INVENTORY")
print("=" * 60)
for kind, count in by_kind.most_common():
    print(f"  {kind:12s} {count}")
print()
print("per file:")
for f, c in by_file.most_common():
    print(f"  {c:4d}  {f}")

comps = [r for r in rows if r[0] == "composable"]
missing = [r for r in comps if r[4] is False]
print()
print(f"composables with no obvious Flutter name match: {len(missing)} of {len(comps)}")
for _, f, line, fn, _ in sorted(missing, key=lambda r: (r[1], r[2])):
    print(f"  {f}:{line}  {fn}")

out = "/tmp/claude-1000/-home-sbvino-Omniterm/d2169d4a-f6e7-45cc-8032-b35043b36c22/scratchpad/inventory.json"
json.dump(
    [{"kind": k, "file": f, "line": l, "name": n, "flutterNameMatch": p} for k, f, l, n, p in rows],
    open(out, "w"),
    indent=1,
)
print(f"\nwrote {out} ({len(rows)} rows)")
