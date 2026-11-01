#!/usr/bin/env python3
"""Generate Flutter's localisation source (ARB) from the production Android app's string resources.

Kotlin is the reference app, and `app/src/main/res/values/strings.xml` holds its user-facing text.
Flutter used to carry its own hand-typed copy of every label, which drifted: a reworded button, a
missing option or a different hint was only found by opening both apps side by side. Generating the
catalogue makes the Kotlin resource the single source — a Flutter screen that uses
`AppLocalizations.of(context).saveServer` cannot disagree with Kotlin's `R.string.save_server`.

Output is the standard Flutter localisation pipeline (flutter_localizations + gen-l10n): an English
template ARB whose keys are the camelCased Android names. `%1$s` / `%2$d` placeholders become ICU
`{a1}` / `{a2}` arguments, so a translation added later works in both apps.

Usage:
  scripts/generate-flutter-strings.py           # rewrite flutter_app/lib/ui/strings.g.dart
  scripts/generate-flutter-strings.py --check   # exit 1 if the committed file is stale (CI)
"""

import argparse
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "app/src/main/res/values/strings.xml"
TARGET = ROOT / "flutter_app/lib/l10n/app_en.arb"

DART_RESERVED = {
    "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const",
    "continue", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends",
    "extension", "external", "factory", "false", "final", "finally", "for", "get", "if",
    "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new", "null",
    "on", "operator", "part", "required", "rethrow", "return", "set", "show", "static", "super",
    "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "while", "with",
    "yield",
}


def android_value(raw: str) -> str:
    """Decode an Android string resource value to the text the user sees."""
    value = raw.strip()
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        value = value[1:-1]
    value = html.unescape(value)
    return (value.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n")
            .replace("\\t", "\t").replace("\\@", "@").replace("\\?", "?"))


def camel(name: str) -> str:
    head, *rest = name.split("_")
    ident = head + "".join(p[:1].upper() + p[1:] for p in rest)
    if ident[0].isdigit():
        ident = "s" + ident
    return ident + "_" if ident in DART_RESERVED else ident


def dart_literal(text: str) -> str:
    escaped = (text.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$")
               .replace("\n", "\\n").replace("\t", "\\t"))
    return f"'{escaped}'"


PLACEHOLDER = re.compile(r"%(\d+)\$([sdf])|%([sdf])")


def generate() -> str:
    import json
    entries = re.findall(r'<string name="([a-z0-9_]+)"([^>]*)>(.*?)</string>', SOURCE.read_text(), re.S)
    arb = {"@@locale": "en"}
    for name, attrs, raw in sorted(entries):
        value = android_value(raw)
        key = camel(name)
        formatted = 'formatted="false"' not in attrs
        placeholders = {}
        if formatted and PLACEHOLDER.search(value):
            order = 0
            def repl(m):
                nonlocal order
                if m.group(1):
                    index = int(m.group(1))
                else:
                    order += 1
                    index = order
                placeholders[f"a{index}"] = {"type": "Object"}
                return "{a" + str(index) + "}"
            value = PLACEHOLDER.sub(repl, value.replace("%%", "\x01")).replace("\x01", "%")
        elif formatted:
            value = value.replace("%%", "%")
        # ICU: a literal brace or apostrophe must be quoted.
        if placeholders:
            value = re.sub(r"'", "''", value)
        arb[key] = value
        meta = {"description": f"Android R.string.{name}"}
        if placeholders:
            meta["placeholders"] = dict(sorted(placeholders.items()))
        arb["@" + key] = meta
    return json.dumps(arb, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = generate()
    if args.check:
        if not TARGET.exists() or TARGET.read_text() != output:
            print(f"{TARGET.relative_to(ROOT)} is stale: run scripts/generate-flutter-strings.py",
                  file=sys.stderr)
            return 1
        print("Flutter string catalogue matches the Kotlin resources.")
        return 0
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(output)
    print(f"Wrote {TARGET.relative_to(ROOT)} ({sum(1 for k in __import__('json').loads(output) if not k.startswith('@'))} strings).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
