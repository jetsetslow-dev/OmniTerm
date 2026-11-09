#!/usr/bin/env python3
"""Fails when Dependabot would open a pull request, so the update lands in our own change instead.

Dependabot's weekly run proposes newer versions of what .github/dependabot.yml covers: the Gradle
dependencies and plugins (the version catalog, coordinates written into build scripts, the plugins
in settings.gradle.kts, the Gradle wrapper), the pinned GitHub Actions and the Go tunnel library's
direct modules (tunnel/go.mod). This asks the same
repositories about the same dependencies, honours the same ignore rules, and lists each update it
finds. check-dependency-advisories.py is its counterpart for known vulnerabilities; that one alone
let AGP 9.5.0 sit for four pushes until Dependabot opened #133. It also lists a newer patch of the
Go toolchain scripts/go-toolchain.sh pins, which Dependabot cannot see: its security fixes ship
inside the app's tunnel library.

Usage: check-dependency-updates.py [--root DIR]
"""
import argparse
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request
import xml.etree.ElementTree as ElementTree

from concurrent.futures import ThreadPoolExecutor

import yaml

GOOGLE = "https://dl.google.com/android/maven2"
CENTRAL = "https://repo1.maven.org/maven2"
PLUGIN_PORTAL = "https://plugins.gradle.org/m2"
GRADLE_CURRENT = "https://services.gradle.org/versions/current"
GO_RELEASES = "https://go.dev/dl/?mode=json"
# settings.gradle.kts limits Google's repository to these groups, as Gradle resolves them.
GOOGLE_GROUPS = re.compile(r"^(com\.android|com\.google|androidx)")
PRERELEASE = re.compile(r"(alpha|beta|rc|cr|milestone|preview|eap|dev|snapshot|(?<![a-z])m\d)", re.I)
COORDINATE = re.compile(r'"([\w.-]+):([\w.-]+):(\d[\w.-]*)"')
SETTINGS_PLUGIN = re.compile(r'id\("([\w.-]+)"\)\s+version\s+"([\w.-]+)"')


def fetch(url, attempts=3, pause=2.0):
    """The body at [url], or None when there is nothing there. A dropped or stalled connection is
    tried again: one read timeout among ~70 parallel fetches ended a gate 40 minutes in (Nov 9)."""
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read().decode()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code < 500 or attempt == attempts:
                sys.exit(f"Could not read {url}: HTTP {e.code}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == attempts:
                sys.exit(f"Could not read {url}: {getattr(e, 'reason', e)}")
        time.sleep(pause * attempt)


def version_tags(repo):
    """[repo]'s version tags and the commit each names, as Dependabot reads Actions. Release names
    are no guide: github/codeql-action's releases are its CodeQL bundles."""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/tags", "--paginate", "--jq", '.[] | "\\(.name) \\(.commit.sha)"'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"Could not read {repo}'s tags: {result.stderr.strip()}")
    pairs = (line.split() for line in result.stdout.splitlines())
    return {name.lstrip("v"): sha for name, sha in pairs if re.fullmatch(r"v?\d+(\.\d+)*", name)}


def version_key(version):
    """A sort key for Maven-style versions: numbers by value, and a pre-release before its release."""
    order = {"alpha": 0, "a": 0, "beta": 1, "b": 1, "milestone": 2, "m": 2, "rc": 3, "cr": 3}
    key = []
    for part in re.findall(r"\d+|[a-z]+", version.lower()):
        if part.isdigit():
            key.append((2, int(part), ""))
        elif part in order:
            key.append((0, order[part], ""))
        else:
            key.append((1, 0, part))
    # A release outranks its own pre-releases: 1.4.0 > 1.4.0-rc1.
    key.append((1.5, 0, ""))
    return key


def suffix(version):
    """What follows the release numbers and is not a pre-release marker, e.g. guava's "-android"."""
    rest = re.sub(r"^\d+(\.\d+)*", "", version)
    return "" if PRERELEASE.search(rest) else rest


def satisfies(version, requirement):
    """[version] against one ignore entry's requirement, e.g. ">= 2.4.10, < 2.5.0" or "2.4.4"."""
    for clause in requirement.split(","):
        m = re.fullmatch(r"\s*(>=|<=|>|<|=|!=)?\s*(\S+)\s*", clause)
        op, bound = (m.group(1) or "="), m.group(2)
        a, b = version_key(version), version_key(bound)
        if not {"=": a == b, "!=": a != b, ">=": a >= b, "<=": a <= b, ">": a > b, "<": a < b}[op]:
            return False
    return True


def update_type(current, candidate):
    cur, new = re.findall(r"\d+", current)[:3], re.findall(r"\d+", candidate)[:3]
    for kind, c, n in zip(("major", "minor", "patch"), cur, new):
        if c != n:
            return f"version-update:semver-{kind}"
    return "version-update:semver-patch"


def ignored(name, current, candidate, rules):
    for rule in rules:
        pattern = "^" + re.escape(rule["dependency-name"]).replace(r"\*", ".*") + "$"
        if not re.match(pattern, name):
            continue
        if not rule.get("versions") and not rule.get("update-types"):
            return True
        if any(satisfies(candidate, r) for r in rule.get("versions", [])):
            return True
        if update_type(current, candidate) in rule.get("update-types", []):
            return True
    return False


def newest(name, current, versions, rules):
    """The version Dependabot would propose for [name] at [current], or None."""
    allow_pre = bool(PRERELEASE.search(current))
    candidates = [
        v for v in versions
        if suffix(v) == suffix(current)
        and (allow_pre or not PRERELEASE.search(v))
        and version_key(v) > version_key(current)
        and not ignored(name, current, v, rules)
    ]
    return max(candidates, key=version_key, default=None)


def maven_versions(group, artifact, plugin=False):
    repos = ([GOOGLE] if GOOGLE_GROUPS.match(group) else []) + [CENTRAL] + ([PLUGIN_PORTAL] if plugin else [])
    found = set()
    for repo in repos:
        body = fetch(f"{repo}/{group.replace('.', '/')}/{artifact}/maven-metadata.xml")
        if body:
            found.update(v.text for v in ElementTree.fromstring(body).iter("version"))
    return found


def gradle_dependencies(root):
    """(Dependabot's name for it, group, artifact, is a plugin, version, where it is set)."""
    catalog = tomllib.loads((root / "gradle/libs.versions.toml").read_text())
    versions = catalog.get("versions", {})

    def resolved(alias, entry):
        """An entry's version and the catalog key that sets it; a BOM-managed library has none."""
        version = entry.get("version")
        if isinstance(version, dict) and "ref" in version:
            return versions.get(version["ref"]), version["ref"]
        return (version, alias) if isinstance(version, str) else (None, alias)

    for alias, lib in catalog.get("libraries", {}).items():
        if isinstance(lib, dict) and "group" in lib:
            version, key = resolved(alias, lib)
            if version:
                yield f"{lib['group']}:{lib['name']}", lib["group"], lib["name"], False, version, f"libs.versions.toml: {key}"
    for alias, plugin in catalog.get("plugins", {}).items():
        version, key = resolved(alias, plugin)
        if version:
            yield plugin["id"], plugin["id"], f"{plugin['id']}.gradle.plugin", True, version, f"libs.versions.toml: {key}"
    # The build scripts Dependabot reads; an init script under .github is not one of them.
    scripts = [p for p in root.rglob("*.gradle.kts") if p.name in ("build.gradle.kts", "settings.gradle.kts")]
    for script in sorted(scripts):
        parts = script.relative_to(root).parts[:-1]
        if "build" in parts or any(part.startswith(".") for part in parts):
            continue
        text = script.read_text()
        where = script.relative_to(root).as_posix()
        for group, artifact, version in COORDINATE.findall(text):
            yield f"{group}:{artifact}", group, artifact, False, version, where
        for plugin_id, version in SETTINGS_PLUGIN.findall(text):
            yield plugin_id, plugin_id, f"{plugin_id}.gradle.plugin", True, version, where


def gradle_wrapper(root):
    properties = (root / "gradle/wrapper/gradle-wrapper.properties").read_text()
    m = re.search(r"gradle-([\d.]+(?:-[\w.]+)?)-(?:bin|all)\.zip", properties)
    return m.group(1) if m else None


def pinned_actions(root):
    """The advisory check's reading of the pinned Actions, so both see the same set."""
    path = pathlib.Path(__file__).with_name("check-dependency-advisories.py")
    spec = importlib.util.spec_from_file_location("check_dependency_advisories", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return list(module.pins(root / ".github"))


def action_update(repo, commit, version, tags, rules):
    """The tag Dependabot would move [repo]'s pin to, or None. A pin is current when it names the
    newest tag's commit, whatever its comment says ("# v2" on v2.38.0's commit is current)."""
    found = newest(repo, version, list(tags), rules)
    return found if found and tags[found] != commit else None


def go_listing(root):
    """`go list -m -u -json all` for tunnel/, with the repository's pinned Go toolchain."""
    if not (root / "tunnel/go.mod").exists():
        return ""
    result = subprocess.run(
        ["bash", "-c", 'eval "$(./scripts/go-toolchain.sh)" && cd tunnel && go list -m -u -json all'],
        cwd=root, capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"Could not list tunnel/'s Go modules: {result.stderr.strip()}")
    return result.stdout


def go_updates(listing, rules):
    """The direct requirements Dependabot would move, from [listing] (`go list -m -u -json all`), as
    (module, version, update). Go chooses the update, so a pseudo-version newer than a module's old
    tags (wireguard-go's) stays; indirect modules follow the modules that need them, as Dependabot
    leaves them."""
    decoder, at, found = json.JSONDecoder(), 0, []
    while at < len(listing):
        while at < len(listing) and listing[at].isspace():
            at += 1
        if at == len(listing):
            break
        module, at = decoder.raw_decode(listing, at)
        update = (module.get("Update") or {}).get("Version")
        if module.get("Main") or module.get("Indirect") or not update:
            continue
        current = module["Version"]
        if not ignored(module["Path"], current.lstrip("v"), update.lstrip("v"), rules):
            found.append((module["Path"], current, update))
    return found


def go_toolchain_update(pinned, releases):
    """A newer stable patch of the pinned Go [pinned] in [releases] (go.dev's JSON), or None."""
    minor = pinned.rsplit(".", 1)[0]
    patches = [
        r["version"].removeprefix("go") for r in releases
        if r.get("stable") and r["version"].removeprefix("go").rsplit(".", 1)[0] == minor
    ]
    newer = [v for v in patches if version_key(v) > version_key(pinned)]
    return max(newer, key=version_key, default=None)


def rules_for(config, ecosystem):
    return [r for u in config["updates"] if u["package-ecosystem"] == ecosystem for r in u.get("ignore", [])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=pathlib.Path(__file__).resolve().parent.parent, type=pathlib.Path)
    args = parser.parse_args()
    root = args.root
    config = yaml.safe_load((root / ".github/dependabot.yml").read_text())
    gradle_rules, action_rules = rules_for(config, "gradle"), rules_for(config, "github-actions")

    updates = []
    dependencies = list({(d[0], d[4]): d for d in gradle_dependencies(root)}.values())
    with ThreadPoolExecutor(max_workers=8) as pool:
        published = pool.map(lambda d: maven_versions(d[1], d[2], d[3]), dependencies)
        for (name, _, _, _, version, where), versions in zip(dependencies, published):
            found = newest(name, version, versions, gradle_rules)
            if found:
                updates.append(f"{name} {version} -> {found} ({where})")
    wrapper = gradle_wrapper(root)
    if wrapper:
        current = json.loads(fetch(GRADLE_CURRENT) or "{}").get("version")
        if current and newest("gradle-wrapper", wrapper, [current], gradle_rules):
            updates.append(f"Gradle wrapper {wrapper} -> {current} (gradle/wrapper/gradle-wrapper.properties)")
    actions = pinned_actions(root)
    tags = {repo: version_tags(repo) for repo in sorted({a[0] for a in actions})}
    for repo, commit, version, path in actions:
        found = action_update(repo, commit, version, tags[repo], action_rules)
        if found:
            updates.append(f"{repo} {version} -> {found} ({path.relative_to(root).as_posix()})")

    go_modules = go_updates(go_listing(root), rules_for(config, "gomod"))
    for module, version, found in go_modules:
        updates.append(f"{module} {version} -> {found} (tunnel/go.mod)")
    pinned_go = re.search(r"^GO_VERSION=(\S+)$", (root / "scripts/go-toolchain.sh").read_text(), re.M)
    if pinned_go:
        found = go_toolchain_update(pinned_go.group(1), json.loads(fetch(GO_RELEASES) or "[]"))
        if found:
            updates.append(f"Go {pinned_go.group(1)} -> {found} (scripts/go-toolchain.sh: version and checksums)")

    checked = f"{len(dependencies)} Gradle, {len(actions)} Actions, Go tunnel modules"
    for line in updates:
        print(line)
    if updates:
        sys.exit(
            f"Dependency updates: {len(updates)} Dependabot would propose ({checked} checked). Take "
            "them in this change, with scripts/refresh-verification-metadata.sh --write, or hold one "
            "in .github/dependabot.yml with the reason."
        )
    print(f"Dependency updates: none Dependabot would propose ({checked} checked).")


if __name__ == "__main__":
    main()
