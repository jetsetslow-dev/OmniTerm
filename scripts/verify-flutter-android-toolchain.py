#!/usr/bin/env python3
"""Keep the separate Flutter Android build on the reviewed production toolchain and policy."""

from pathlib import Path
import re
import tomllib

root = Path(__file__).resolve().parents[1]
android = root / "flutter_app/android"
versions = tomllib.loads((root / "gradle/libs.versions.toml").read_text())["versions"]
settings = (android / "settings.gradle.kts").read_text()
for plugin, key in [("com.android.application", "agp"), ("org.jetbrains.kotlin.android", "kotlin")]:
    match = re.search(r'id\("' + re.escape(plugin) + r'"\) version "([^"]+)"', settings)
    if not match or match[1] != versions[key]:
        raise SystemExit(f"Flutter Android {plugin} must match the reviewed catalog: {versions[key]}")
for name in ["gradle-wrapper.properties", "gradle-wrapper.jar"]:
    relative = Path("gradle/wrapper") / name
    if (android / relative).read_bytes() != (root / relative).read_bytes():
        raise SystemExit(f"Flutter Android {name} must match the reviewed production wrapper")
native = (root / "build.gradle.kts").read_text()
expected = native[:native.index("// Top-level build file")] + native[native.index("val kotlinBaseline ="):]
flutter = (android / "build.gradle.kts").read_text()
actual = flutter.split("// BEGIN production dependency security policy\n", 1)[1].split(
    "// END production dependency security policy", 1
)[0]
if actual != expected:
    raise SystemExit("Flutter Android dependency security policy differs from the production build")
if "implementation(libs.bcprov)" not in (android / "app/build.gradle.kts").read_text():
    raise SystemExit("Flutter Android must use the reviewed catalog's Bouncy Castle provider")
print("Flutter Android toolchain, wrapper and dependency security policy match production.")
