#!/usr/bin/env python3
"""Checks what a release publishes, from the built files, before anything is uploaded.

A GitHub release carries the open-source app as one APK per processor architecture next to a
universal APK that works on every phone. Google Play gets the bundle and serves each phone its own
part itself. 32-bit x86 is not built. Every APK of a release has the release's version name and
version code, the same as the bundle's (a different package), so a phone moves between the
universal APK and the one for its processor, either way, without uninstalling: Android installs an
equal version code as an update and refuses only a lower one. Per-architecture version codes exist
for uploading several APKs to Play, which this app does not do.

This reads the files back (aapt2 and apksigner from the Android SDK's build tools) and fails unless:

  - the APKs are exactly OmniTerm-OpenSource-<tag>.apk (universal) and
    OmniTerm-OpenSource-<tag>-<abi>.apk for arm64-v8a, armeabi-v7a and x86_64;
  - each per-architecture APK holds native code for its own architecture only, and the universal
    APK and the bundle for all three, so none holds 32-bit x86;
  - every APK is the open-source package, the bundle the Play one, all with the tag's version name
    and the release's version code;
  - every APK is signed, all by one certificate, as an update must be.

  verify-release-apks.py --label vX.Y.Z[-SuffixN] --version-code N [--apks DIR] [--bundle AAB]

The release workflow runs it on what it built; scripts/local-pr-check.sh --full on its own release
build; scripts/test-verify-release-apks.py shows each rule failing on a wrong file. The build tools
are the newest under ANDROID_HOME (or ANDROID_SDK_ROOT) unless --build-tools names a folder.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
APK_PACKAGE = "com.jetsetslow.omniterm.app.oss"
BUNDLE_PACKAGE = "com.jetsetslow.omniterm.app"


def expected_apks(label: str) -> dict[str, str | None]:
    """Each APK's file name and the architecture it is for (None: universal)."""
    names: dict[str, str | None] = {f"OmniTerm-OpenSource-{label}.apk": None}
    names |= {f"OmniTerm-OpenSource-{label}-{abi}.apk": abi for abi in ABIS}
    return names


def native_abis(archive: Path) -> set[str]:
    """The architectures an APK (lib/<abi>/) or a bundle (<module>/lib/<abi>/) has native code for."""
    found = set()
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            parts = name.split("/")
            if not name.endswith(".so"):
                continue
            if len(parts) >= 3 and parts[0] == "lib":
                found.add(parts[1])
            elif len(parts) >= 4 and parts[1] == "lib":
                found.add(parts[2])
    return found


def build_tools(explicit: Path | None) -> Path:
    if explicit:
        return explicit
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        raise SystemExit("verify-release-apks: set ANDROID_HOME to the Android SDK, or pass --build-tools")
    found = [d for d in (Path(sdk) / "build-tools").glob("*") if (d / "aapt2").exists() and (d / "apksigner").exists()]
    if not found:
        raise SystemExit(f"verify-release-apks: no build tools with aapt2 and apksigner under {sdk}/build-tools")
    return max(found, key=lambda d: [int(p) if p.isdigit() else -1 for p in re.split(r"[.-]", d.name)])


def run(*command: object) -> tuple[bool, str]:
    result = subprocess.run([str(c) for c in command], capture_output=True, text=True)
    return result.returncode == 0, result.stdout if result.returncode == 0 else (result.stderr or result.stdout).strip()


def badging(tools: Path, apk: Path) -> tuple[str, int, str] | str:
    """Package, version code and version name, or why they could not be read."""
    ok, out = run(tools / "aapt2", "dump", "badging", apk)
    m = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'", out, re.M) if ok else None
    if not m:
        return f"aapt2 cannot read its manifest: {out.splitlines()[0] if out else 'no package line'}"
    return m.group(1), int(m.group(2)), m.group(3)


def bundle_badging(tools: Path, bundle: Path) -> tuple[str, int, str] | str:
    # A bundle keeps its manifest and resource table in protobuf form under base/; aapt2 reads them
    # as a proto-format APK once they sit at the root of an archive.
    with tempfile.TemporaryDirectory() as tmp:
        proto = Path(tmp) / "base.apk"
        try:
            with zipfile.ZipFile(bundle) as src, zipfile.ZipFile(proto, "w") as dst:
                dst.writestr("AndroidManifest.xml", src.read("base/manifest/AndroidManifest.xml"))
                dst.writestr("resources.pb", src.read("base/resources.pb"))
        except KeyError as missing:
            return f"no base module manifest or resource table ({missing})"
        except zipfile.BadZipFile:
            return "not a zip archive"
        return badging(tools, proto)


def certificates(tools: Path, apk: Path) -> set[str] | str:
    """The signing certificates' SHA-256 digests, or why the signature does not verify."""
    ok, out = run(tools / "apksigner", "verify", "--print-certs", apk)
    if not ok:
        return f"not signed, or the signature does not verify: {out.splitlines()[0] if out else ''}"
    return set(re.findall(r"certificate SHA-256 digest: ([0-9a-f]{64})", out)) or "no signing certificate"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", required=True, help="the release tag, vX.Y.Z[-SuffixN]")
    parser.add_argument("--version-code", required=True, type=int, help="the release's version code")
    parser.add_argument("--apks", type=Path, help="the folder holding the release's APKs")
    parser.add_argument("--bundle", type=Path, help="the Play bundle")
    parser.add_argument("--build-tools", type=Path)
    args = parser.parse_args(argv)
    if not args.apks and not args.bundle:
        parser.error("name --apks, --bundle or both")
    tools = build_tools(args.build_tools)
    want = args.version_code, args.label.removeprefix("v")
    problems: list[str] = []
    rows: list[tuple[str, str, str, str, int]] = []

    def identity(name: str, package: str, found: tuple[str, int, str] | str) -> str:
        if isinstance(found, str):
            problems.append(f"{name}: {found}")
            return "unreadable"
        if found != (package, *want):
            problems.append(f"{name}: {found[0]} version {found[2]} ({found[1]}), expected {package} version {want[1]} ({want[0]})")
        return f"{found[2]} ({found[1]})"

    def code_for(name: str, archive: Path, wanted: set[str]) -> str:
        try:
            abis = native_abis(archive)
        except zipfile.BadZipFile:
            problems.append(f"{name}: not a zip archive")
            return "unreadable"
        if abis != wanted:
            problems.append(f"{name}: native code for {', '.join(sorted(abis)) or 'nothing'}, expected {', '.join(sorted(wanted))}")
        return ", ".join(sorted(abis)) or "none"

    if args.apks:
        expected = expected_apks(args.label)
        present = {p.name for p in args.apks.glob("*.apk")}
        problems += [f"missing {name}" for name in sorted(expected.keys() - present)]
        problems += [f"unexpected APK {name}" for name in sorted(present - expected.keys())]
        files = [(name, args.apks / name, abi) for name, abi in expected.items() if name in present]
        with ThreadPoolExecutor() as pool:
            signed = list(pool.map(lambda f: certificates(tools, f[1]), files))
        for (name, apk, abi), certs in zip(files, signed):
            version = identity(name, APK_PACKAGE, badging(tools, apk))
            abis = code_for(name, apk, {abi} if abi else set(ABIS))
            if isinstance(certs, str):
                problems.append(f"{name}: {certs}")
            rows.append((name, abi or "universal", version, abis, apk.stat().st_size))
        certified = {frozenset(c) for c in signed if not isinstance(c, str)}
        if len(certified) > 1:
            problems.append("the APKs are not all signed by the same certificate, so one cannot replace another")

    if args.bundle:
        if args.bundle.is_file():
            version = identity(args.bundle.name, BUNDLE_PACKAGE, bundle_badging(tools, args.bundle))
            abis = code_for(args.bundle.name, args.bundle, set(ABIS))
            rows.append((args.bundle.name, "Play bundle", version, abis, args.bundle.stat().st_size))
        else:
            problems.append(f"missing {args.bundle}")

    if rows:
        width = max(len(r[0]) for r in rows)
        for name, kind, version, abis, size in rows:
            print(f"{name:<{width}}  {kind:<11}  {version:<24}  {size / 1e6:7.2f} MB  {abis}")
    if problems:
        print("verify-release-apks: the release files are wrong:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 1
    print("verify-release-apks: every file has the release's version and exactly the architectures its name says"
          + (", every APK signed alike" if args.apks else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
