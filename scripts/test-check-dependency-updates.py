#!/usr/bin/env python3
"""Pins scripts/check-dependency-updates.py without the network: which versions it proposes, the
dependabot.yml rules it honours, how it reads Action pins, and where it finds Gradle versions."""
import importlib.util
import pathlib
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_dependency_updates", HERE / "check-dependency-updates.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def expect(got, want, what):
    if got != want:
        raise SystemExit(f"check-dependency-updates: {what}: expected {want!r}, got {got!r}")


ordered = ["1.4.0-alpha05", "1.4.0-alpha07", "1.4.0-beta01", "1.4.0-rc01", "1.4.0", "1.4.0.1", "1.4.1", "1.10.0"]
expect(sorted(reversed(ordered), key=check.version_key), ordered, "version order")
expect(check.version_key("2026.09.00") < check.version_key("2026.10.00"), True, "BOM dates")

rules = [
    {"dependency-name": "org.jetbrains.kotlin.plugin.compose", "versions": [">= 2.4.10, < 2.5.0"]},
    {"dependency-name": "ossf/scorecard-action", "versions": ["2.4.4"]},
    {"dependency-name": "com.squareup.retrofit2:*", "update-types": ["version-update:semver-major"]},
]
newest = check.newest
expect(newest("a:b", "1.18.0", ["1.19.0-rc01", "1.18.1"], rules), "1.18.1", "a release skips pre-releases")
expect(newest("a:b", "1.4.0-alpha05", ["1.4.0-alpha07", "1.4.0-alpha06"], rules), "1.4.0-alpha07", "a pre-release takes pre-releases")
expect(newest("g:guava", "33.7.2-android", ["33.8.0-jre", "33.8.0-android"], rules), "33.8.0-android", "a variant keeps its suffix")
expect(newest("org.jetbrains.kotlin.plugin.compose", "2.4.0", ["2.4.10", "2.4.20"], rules), None, "a held range")
expect(newest("org.jetbrains.kotlin.plugin.compose", "2.4.0", ["2.4.20", "2.5.0"], rules), "2.5.0", "past a held range")
expect(newest("ossf/scorecard-action", "2.4.3", ["2.4.4"], rules), None, "a held version")
expect(newest("com.squareup.retrofit2:retrofit", "2.12.0", ["3.0.0"], rules), None, "a held major")
expect(newest("com.squareup.retrofit2:retrofit", "2.12.0", ["3.0.0", "2.13.0"], rules), "2.13.0", "a minor past a held major")
expect(newest("a:b", "1.0.0", ["0.9.0", "1.0.0"], rules), None, "nothing newer")

tags = {"2": "aaa", "2.38.0": "aaa", "2.37.0": "bbb"}
expect(check.action_update("o/r", "aaa", "2", tags, []), None, "a major comment on the newest commit is current")
expect(check.action_update("o/r", "bbb", "2.37.0", tags, []), "2.38.0", "an older commit moves to the newest tag")

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    (root / "gradle").mkdir()
    (root / "gradle/libs.versions.toml").write_text(
        '[versions]\ncore = "1.18.0"\nagp = "9.4.1"\n'
        '[libraries]\n'
        'core = { group = "androidx.core", name = "core-ktx", version.ref = "core" }\n'
        'direct = { group = "x.y", name = "z", version = "2.0" }\n'
        'bom-managed = { group = "androidx.compose.ui", name = "ui" }\n'
        '[plugins]\napp = { id = "com.android.application", version.ref = "agp" }\n'
    )
    (root / "app/build/generated").mkdir(parents=True)
    (root / "app/build.gradle.kts").write_text('implementation("androidx.glance:glance-appwidget:1.1.1")\n')
    (root / "app/build/generated/build.gradle.kts").write_text('implementation("not.read:built:1.0")\n')
    (root / "settings.gradle.kts").write_text('plugins {\n  id("com.gradle.develocity") version "4.6.1"\n}\n')
    (root / ".github").mkdir()
    (root / ".github/cyclonedx.init.gradle.kts").write_text('classpath("not.read:init:1.0")\n')
    found = sorted((d[0], d[4], d[5]) for d in check.gradle_dependencies(root))
    expect(found, [
        ("androidx.core:core-ktx", "1.18.0", "libs.versions.toml: core"),
        ("androidx.glance:glance-appwidget", "1.1.1", "app/build.gradle.kts"),
        ("com.android.application", "9.4.1", "libs.versions.toml: agp"),
        ("com.gradle.develocity", "4.6.1", "settings.gradle.kts"),
        ("x.y:z", "2.0", "libs.versions.toml: direct"),
    ], "Gradle versions found")

print("check-dependency-updates checks passed.")
