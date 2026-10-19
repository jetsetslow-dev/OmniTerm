#!/usr/bin/env python3
"""Static Kotlin ↔ Flutter parity audit.

The production app is Kotlin (`app/`); the Flutter app (`flutter_app/`) must match it label for
label, option for option. Finding the differences by opening screens side by side does not scale and
misses whole dialogs, so this lists them mechanically:

* ``kotlin-only``  — user-facing Kotlin strings (Compose literals and resolved string resources)
  that appear nowhere in the Flutter UI. A missing feature, option, dialog or a reworded label.
* ``flutter-only`` — Flutter UI strings that appear nowhere in Kotlin. A Flutter-only addition
  (which the project ports to Kotlin) or a reworded label.
* ``settings``     — persisted ``app_settings`` keys present in one app only.
* ``style``        — labels present in both apps whose font size, weight, family or alignment
  differ (explicit values only; an unset value means the inherited default).

Differences are expected while the port is in progress, so the check compares against a committed
baseline: it fails only on a difference that is NOT in the baseline (a regression) and reports
baseline entries that no longer occur (fixed — remove them with ``--update-baseline``). Intentional,
permanent differences belong in the allowlist with a reason, not in the baseline.

Usage:
  scripts/parity-audit.py                     # check against scripts/parity/baseline.json
  scripts/parity-audit.py --report out.md     # also write a readable report
  scripts/parity-audit.py --update-baseline   # accept the current differences as the baseline
"""

import argparse
import html
import json
import pathlib
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ in the tree
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "parity"))
from style_extract import flutter_styles, kotlin_styles  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
KOTLIN_UI = ROOT / "app/src/main/java/com/jetsetslow/omniterm"
KOTLIN_STRINGS = ROOT / "app/src/main/res/values/strings.xml"
FLUTTER_LIB = ROOT / "flutter_app/lib"
PARITY_DIR = ROOT / "scripts/parity"
BASELINE = PARITY_DIR / "baseline.json"
ALLOWLIST = PARITY_DIR / "allowlist.json"

# Calls whose first string argument is shown to the user.
KOTLIN_UI_CALL = (
    r"(?:Text|label\s*=|title\s*=|contentDescription\s*=|subtitle\s*=|placeholder\s*=|"
    r"confirmLabel\s*=|OmniButton|TerminalToggleRow|SectionHeader|ask|"
    r"Toast\.makeText\([^,]+,)\s*\(?\s*"
)
FLUTTER_UI_CALL = (
    r"(?:Text\(|label:\s*|labelText:\s*|title:\s*|tooltip:\s*|subtitle:\s*|hintText:\s*|"
    r"semanticLabel:\s*|message:\s*|content:\s*Text\()\s*(?:const\s+)?(?:Text\()?\s*"
)
SETTING_CALL_KOTLIN = r"(?:insertSetting|getSetting|put)\(\s*\"([a-z][a-z0-9_]+)\""
SETTING_LITERAL_FLUTTER = r"'([a-z][a-z0-9]*(?:_[a-z0-9]+)+)'"


def kotlin_resources() -> dict:
    text = KOTLIN_STRINGS.read_text()
    out = {}
    for m in re.finditer(r'<string name="([a-z0-9_]+)"[^>]*>(.*?)</string>', text, re.S):
        value = m.group(2).strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        out[m.group(1)] = (
            html.unescape(value).replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n")
        )
    return out


def norm(text: str) -> str:
    """Interpolations become a separator, so `"Host $name"` and `'Host ${name}'` compare equal."""
    text = re.sub(r"\$\{[^}]*\}|\$[a-zA-Z_]+|%\d\$[sd]|%[sd]", "\x00", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def fragments(text: str) -> list:
    return [p.strip() for p in norm(text).split("\x00") if len(p.strip()) >= 4]


def corpus(paths) -> str:
    """All source text joined, adjacent string literals merged so wrapped strings still match."""
    text = "\n".join(p.read_text(errors="ignore") for p in paths)
    text = re.sub(r"'\s*\n\s*'", "", text)            # Dart 'a ' 'b'
    text = re.sub(r'"\s*\+\s*\n?\s*"', "", text)      # Kotlin "a " + "b"
    return re.sub(r"\s+", " ", html.unescape(text).replace("\\'", "'")).lower()


def kotlin_files():
    return sorted(p for p in KOTLIN_UI.rglob("*.kt"))


def flutter_files():
    return sorted(p for p in FLUTTER_LIB.rglob("*.dart") if not p.name.endswith(".g.dart"))


def kotlin_ui_strings(resources: dict) -> dict:
    out = {}
    for path in kotlin_files():
        text = re.sub(r'"\s*\+\s*\n?\s*"', "", path.read_text(errors="ignore"))
        found = {resources[m.group(1)] for m in re.finditer(r"R\.string\.([a-z0-9_]+)", text)
                 if m.group(1) in resources}
        found |= {m.group(1).replace('\\"', '"').replace("\\n", "\n")
                  for m in re.finditer(KOTLIN_UI_CALL + r'"((?:[^"\\$]|\\.){3,})"', text)}
        for s in found:
            if fragments(s):
                out.setdefault(s, path.relative_to(ROOT).as_posix())
    return out


def flutter_ui_strings() -> dict:
    out = {}
    for path in flutter_files():
        text = re.sub(r"'\s*\n\s*'", "", path.read_text(errors="ignore"))
        for m in re.finditer(FLUTTER_UI_CALL + r"'((?:[^'\\]|\\.){4,})'", text):
            s = m.group(1).replace("\\'", "'")
            if fragments(s):
                out.setdefault(s, path.relative_to(ROOT).as_posix())
    return out


def settings_keys():
    kotlin = set()
    for path in kotlin_files():
        kotlin |= set(re.findall(SETTING_CALL_KOTLIN, path.read_text(errors="ignore")))
    flutter_text = corpus(flutter_files())
    # Kotlin keys absent from every Flutter source file.
    kotlin_only = sorted(k for k in kotlin if f"'{k}'" not in flutter_text)
    # Flutter keys: literals used with the settings store that Kotlin never mentions.
    kotlin_text = corpus(kotlin_files())
    flutter = set()
    for path in flutter_files():
        text = path.read_text(errors="ignore")
        if "Setting(" in text or "app_settings" in text or "keys = {" in text:
            flutter |= set(re.findall(SETTING_LITERAL_FLUTTER, text))
    flutter_only = sorted(k for k in flutter if f'"{k}"' not in kotlin_text and k not in kotlin)
    return kotlin_only, flutter_only


def audit() -> dict:
    resources = kotlin_resources()
    flutter_text = corpus(flutter_files())
    kotlin_text = corpus(kotlin_files()) + " " + " ".join(resources.values()).lower()

    def present(text, haystack):
        return all(fragment in haystack for fragment in fragments(text))

    kotlin_only = {s: f for s, f in kotlin_ui_strings(resources).items() if not present(s, flutter_text)}
    flutter_only = {s: f for s, f in flutter_ui_strings().items() if not present(s, kotlin_text)}
    settings_kotlin_only, settings_flutter_only = settings_keys()
    return {
        "style": style_differences(resources),
        "kotlin-only": {f"{f} :: {s}": True for s, f in kotlin_only.items()},
        "flutter-only": {f"{f} :: {s}": True for s, f in flutter_only.items()},
        "settings": {**{f"kotlin-only :: {k}": True for k in settings_kotlin_only},
                     **{f"flutter-only :: {k}": True for k in settings_flutter_only}},
    }


def style_differences(resources: dict) -> dict:
    kotlin, flutter = {}, {}
    for path in kotlin_files():
        for label, st in kotlin_styles(path.read_text(errors="ignore"), resources).items():
            kotlin.setdefault(norm(label), (label, st, path.relative_to(ROOT).as_posix()))
    for path in flutter_files():
        for label, st in flutter_styles(path.read_text(errors="ignore")).items():
            flutter.setdefault(norm(label), (label, st, path.relative_to(ROOT).as_posix()))
    out = {}
    for key in sorted(set(kotlin) & set(flutter)):
        label, kst, kfile = kotlin[key]
        _, fst, ffile = flutter[key]
        diffs = []
        if "size" in kst and "size" in fst and kst["size"] != fst["size"]:
            diffs.append(f"size {kst['size']:g}≠{fst['size']:g}")
        for attr in ("weight", "align", "family"):
            if (kst.get(attr) or "default") != (fst.get(attr) or "default"):
                diffs.append(f"{attr} {kst.get(attr) or 'default'}≠{fst.get(attr) or 'default'}")
        if diffs:
            out[f"{label.replace(chr(10), ' ')[:70]} :: kotlin {kfile.split('/')[-1]} vs flutter {ffile.split('/')[-1]} :: {', '.join(diffs)}"] = True
    return out


def load(path: pathlib.Path) -> dict:
    return json.loads(path.read_text()) if path.exists() else {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--report", type=pathlib.Path)
    args = parser.parse_args()

    found = audit()
    allow = {k: v for k, v in load(ALLOWLIST).items() if not k.startswith("_")}
    for section in found:
        for entry in list(found[section]):
            if entry in allow.get(section, {}):
                del found[section][entry]

    if args.update_baseline:
        PARITY_DIR.mkdir(parents=True, exist_ok=True)
        BASELINE.write_text(json.dumps({k: sorted(v) for k, v in found.items()}, indent=1,
                                       ensure_ascii=False) + "\n")
        print(f"Baseline written: {sum(len(v) for v in found.values())} known differences.")
        return 0

    baseline = {k: set(v) for k, v in load(BASELINE).items()}
    new = {k: sorted(set(v) - baseline.get(k, set())) for k, v in found.items()}
    fixed = {k: sorted(baseline.get(k, set()) - set(v)) for k, v in found.items()}

    if args.report:
        lines = ["# Kotlin ↔ Flutter parity audit", ""]
        for section, entries in found.items():
            lines += [f"## {section} ({len(entries)})", ""]
            lines += [f"- {e.replace(chr(10), ' ')}" for e in sorted(entries)] + [""]
        args.report.write_text("\n".join(lines))

    for section in found:
        print(f"{section:13s} {len(found[section]):4d} known   "
              f"{len(new[section]):3d} new   {len(fixed[section]):3d} fixed")
    for section, entries in fixed.items():
        for e in entries:
            print(f"FIXED  [{section}] {e}  (remove with --update-baseline)")
    regressions = [(s, e) for s, entries in new.items() for e in entries]
    for section, e in regressions:
        print(f"NEW    [{section}] {e.replace(chr(10), ' ')}", file=sys.stderr)
    if regressions:
        print(f"{len(regressions)} new Kotlin↔Flutter difference(s). Fix them, or allowlist "
              "an intentional one in scripts/parity/allowlist.json with a reason.", file=sys.stderr)
        return 1
    print("No new Kotlin↔Flutter differences.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
