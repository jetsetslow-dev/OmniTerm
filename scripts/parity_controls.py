#!/usr/bin/env python3
"""Enumerate every interactive control in both apps and pair them up.

`scripts/inventory.py` works at the level of composables and screens. That was enough to order a
queue, and not enough to catch what actually goes wrong: the backup passphrase defect (parity ledger
101) was a *single button's enabled-condition* disagreeing with the check behind it, inside a screen
both apps clearly "had". Nothing screen-shaped would ever have surfaced it.

So this walks controls, not screens: buttons, switches, checkboxes, sliders, text fields, menu
items, taps, long-presses and drags — on both sides — and emits one row each with the label or key
that identifies it, plus the enabled-condition where the source states one.

The pairing is by normalised label and is a **heuristic**. A row marked unmatched is a question, not
a defect: half of them are wording differences, and the ledger records several cases where the
behaviour was present under a different name. What the tool guarantees is that the *queue is finite
and every control is in it*.

Usage:
    python3 scripts/parity_controls.py            # summary to stdout
    python3 scripts/parity_controls.py --json OUT # full rows for further analysis
"""

import argparse
import json
import os
import re
from collections import Counter

KOTLIN_UI = "app/src/main/java/com/jetsetslow/omniterm/ui"
FLUTTER_LIB = "flutter_app/lib"

# (category, regex). Each pattern captures the control's opening so the label search can start there.
KOTLIN_CONTROLS = [
    ("button", re.compile(r"\b(?:Text|Outlined|Filled|FilledTonal|Elevated)?Button\s*\(")),
    ("icon-button", re.compile(r"\bIconButton\s*\(")),
    ("fab", re.compile(r"\bFloating(?:Action)?Button\s*\(")),
    ("switch", re.compile(r"\bSwitch\s*\(")),
    ("checkbox", re.compile(r"\bCheckbox\s*\(")),
    ("radio", re.compile(r"\bRadioButton\s*\(")),
    ("slider", re.compile(r"\bSlider\s*\(")),
    ("text-field", re.compile(r"\b(?:Outlined)?TextField\s*\(|\bOmni\w*Field\s*\(")),
    ("menu-item", re.compile(r"\bDropdownMenuItem\s*\(")),
    ("chip", re.compile(r"\b(?:Filter|Assist|Input|Suggestion)Chip\s*\(")),
    ("tap", re.compile(r"\.clickable\s*[({]")),
    ("long-press", re.compile(r"onLongClick\s*=")),
    ("drag", re.compile(r"detectDrag\w*|detectTransformGestures|draggable\s*\(")),
]

FLUTTER_CONTROLS = [
    ("button", re.compile(r"\b(?:Text|Outlined|Filled|Elevated)Button(?:\.icon)?\s*\(")),
    ("icon-button", re.compile(r"\bIconButton\s*\(")),
    ("fab", re.compile(r"\bFloatingActionButton(?:\.small|\.large|\.extended)?\s*\(")),
    ("switch", re.compile(r"\bSwitch(?:ListTile)?\s*\(")),
    ("checkbox", re.compile(r"\bCheckbox(?:ListTile)?\s*\(")),
    ("radio", re.compile(r"\bRadio(?:ListTile)?\s*<")),
    ("slider", re.compile(r"\bSlider\s*\(")),
    ("text-field", re.compile(r"\bTextField\s*\(|\bTextFormField\s*\(")),
    ("menu-item", re.compile(r"\bPopupMenuItem\s*[<(]|\bDropdownMenuItem\s*[<(]")),
    ("chip", re.compile(r"\b(?:Filter|Action|Input|Choice)Chip\s*\(")),
    ("tap", re.compile(r"\bonTap\s*:")),
    ("long-press", re.compile(r"\bonLongPress\s*:")),
    ("drag", re.compile(r"\bonPanUpdate\s*:|\bonHorizontalDrag\w*\s*:|\bDismissible\s*\(")),
]

# The identifying text: a Compose `text = "..."`/`label = "..."`, a Flutter `Text('...')`, or a
# ValueKey. Searched in a window after the control opens, because Compose and Flutter both put the
# label a few lines below the constructor.
LABEL_PATTERNS = [
    re.compile(r"""ValueKey\(\s*['"]([^'"]+)['"]"""),
    re.compile(r"""stringResource\(R\.string\.(\w+)\)"""),
    re.compile(r"""Text\(\s*['"]([^'"]{2,60})['"]"""),
    re.compile(r"""(?:text|label|title|tooltip|contentDescription)\s*[:=]\s*['"]([^'"]{2,60})['"]"""),
]

ENABLED = re.compile(r"\benabled\s*[:=]\s*([^,\n]{1,80})")
ON_PRESSED_NULL = re.compile(r"onPressed\s*:\s*null")
# Dart's usual gate is not `enabled:` but a ternary that hands `onPressed` a null: `cond ? null : ()`
# disables when cond holds, `cond ? () : null` disables when it does not. Both are gates; missing
# them made the first run report every Flutter peer as ungated.
ON_PRESSED_TERNARY = re.compile(r"on(?:Pressed|Tap|Changed)\s*:\s*([^,\n]{1,80}\?[^,\n]{0,80})")


def string_resources(path: str) -> dict:
    """Map `R.string.foo` to the English text, so Kotlin labels can be compared with Flutter's.

    Without this, every Compose control labelled from a resource looks absent from Flutter — the
    first run reported 'connect_non_resumable' missing while the peer sat in
    connection_prompt_host.dart, correctly gated.
    """
    try:
        raw = open(path, encoding="utf-8").read()
    except OSError:
        return {}
    return {
        name: re.sub(r"\\'", "'", text)
        for name, text in re.findall(r'<string name="([^"]+)"[^>]*>(.*?)</string>', raw, re.S)
    }


def norm(label: str) -> str:
    """Fold wording differences that are not behaviour: case, punctuation, ellipsis, key prefixes."""
    text = label.lower().strip()
    text = text.split(".")[-1] if text.count(".") and " " not in text else text
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def scan(root: str, patterns, window: int = 400, strings: dict | None = None):
    rows = []
    for base, _, files in os.walk(root):
        for name in sorted(files):
            if not (name.endswith(".kt") or name.endswith(".dart")):
                continue
            if name.endswith(".g.dart") or name.endswith(".freezed.dart"):
                continue
            path = os.path.join(base, name)
            src = open(path, encoding="utf-8", errors="replace").read()
            for category, pattern in patterns:
                for match in pattern.finditer(src):
                    tail = src[match.start(): match.start() + window]
                    label = ""
                    for label_pattern in LABEL_PATTERNS:
                        found = label_pattern.search(tail)
                        if found:
                            label = found.group(1)
                            break
                    if not label:
                        # Compose usually writes `Row { Text("AMOLED black"); Switch(...) }` — the
                        # label precedes the control rather than following it, which is why the
                        # forward-only search left 301 controls unlabelled and uncompared. Take the
                        # *nearest* preceding label so a Row's own text wins over the section above.
                        head = src[max(0, match.start() - window): match.start()]
                        best = -1
                        for label_pattern in LABEL_PATTERNS:
                            for found in label_pattern.finditer(head):
                                if found.start() > best:
                                    best, label = found.start(), found.group(1)
                    if strings and label in strings:
                        label = strings[label]
                    enabled = ""
                    gate = ENABLED.search(tail) or ON_PRESSED_TERNARY.search(tail)
                    if gate:
                        enabled = gate.group(1).strip()
                    elif ON_PRESSED_NULL.search(tail):
                        enabled = "false (onPressed: null)"
                    rows.append({
                        "file": os.path.relpath(path),
                        "line": src.count("\n", 0, match.start()) + 1,
                        "category": category,
                        "label": label,
                        "norm": norm(label),
                        "enabled": enabled,
                    })
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", help="write the full rows here")
    args = parser.parse_args()

    strings = string_resources("app/src/main/res/values/strings.xml")
    kotlin = scan(KOTLIN_UI, KOTLIN_CONTROLS, strings=strings)
    flutter = scan(FLUTTER_LIB, FLUTTER_CONTROLS)

    flutter_labels = {row["norm"] for row in flutter if row["norm"]}
    kotlin_labels = {row["norm"] for row in kotlin if row["norm"]}

    unmatched_kotlin = [r for r in kotlin if r["norm"] and r["norm"] not in flutter_labels]
    unmatched_flutter = [r for r in flutter if r["norm"] and r["norm"] not in kotlin_labels]
    unlabelled_kotlin = [r for r in kotlin if not r["norm"]]

    print(f"Kotlin controls   : {len(kotlin):5d}  ({len(kotlin_labels)} distinct labels)")
    print(f"Flutter controls  : {len(flutter):5d}  ({len(flutter_labels)} distinct labels)")
    print(f"Kotlin unmatched  : {len(unmatched_kotlin):5d}  <- the queue")
    print(f"Flutter unmatched : {len(unmatched_flutter):5d}  <- Flutter-only, check for invented scope")
    print(f"Kotlin unlabelled : {len(unlabelled_kotlin):5d}  <- need reading by hand, no label to match on")
    print()
    print("By category (kotlin / flutter):")
    kc, fc = Counter(r["category"] for r in kotlin), Counter(r["category"] for r in flutter)
    for category in sorted(set(kc) | set(fc)):
        print(f"  {category:12s} {kc.get(category, 0):5d} / {fc.get(category, 0):5d}")

    gated = [r for r in kotlin if r["enabled"]]
    print()
    print(f"Kotlin controls with an explicit enabled-condition: {len(gated)}")
    print("  (ledger 101 lived in one of these — the condition disagreed with the check behind it)")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "kotlin": kotlin,
                    "flutter": flutter,
                    "unmatched_kotlin": unmatched_kotlin,
                    "unmatched_flutter": unmatched_flutter,
                    "unlabelled_kotlin": unlabelled_kotlin,
                },
                handle,
                indent=1,
            )
        print(f"\nFull rows written to {args.json}")


if __name__ == "__main__":
    main()
