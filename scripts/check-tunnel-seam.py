#!/usr/bin/env python3
"""Fails when a tunnel library or an app holds the Cloudflare Access test seam.

Only `scripts/build-tunnel.sh --access-fixture` builds the seam (Go tag omniterm_access_fixture):
a test library that trusts the contract fake's CA and sends the fake's names to a local endpoint,
for E2eCloudflareAccessTunnelTest. No library or app that ships may hold it.

    check-tunnel-seam.py FILE...            each .aar, .apk or .aab must be free of it
    check-tunnel-seam.py --built            the repository's built library and app outputs
    check-tunnel-seam.py --expect-fixture FILE
                                            FILE must hold it (the fixture build checks itself)

Archives inside archives (an AAR's classes.jar) are searched too. An instrumentation test APK is
not an app and is skipped by --built: the device suite that drives the seam is in it.
"""
import io
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The Go function's name, in each native library and in the Java class gomobile writes for it,
# and a name only the fixture's transport knows.
MARKERS = (b"CloudflareFixture", b"cloudflareFixture", b"ssh.access.test")
ARCHIVES = (".aar", ".apk", ".aab", ".jar", ".zip")


def seams(data: bytes, name: str):
    """Yields each entry of the archive data (named name) that holds a marker."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            body = archive.read(entry)
            where = f"{name}!{entry.filename}"
            if entry.filename.endswith(ARCHIVES) and zipfile.is_zipfile(io.BytesIO(body)):
                yield from seams(body, where)
            elif any(marker in body for marker in MARKERS):
                yield where


def built() -> list[Path]:
    outputs = [ROOT / "tunnel/build/omnitunnel.aar"]
    for folder, pattern in (("app/build/outputs/apk", "*.apk"), ("app/build/outputs/bundle", "*.aab")):
        outputs += sorted(p for p in (ROOT / folder).rglob(pattern) if "androidTest" not in p.relative_to(ROOT).parts)
    return [p for p in outputs if p.is_file()]


def main(argv: list[str]) -> int:
    expect = argv[:1] == ["--expect-fixture"]
    if expect:
        argv = argv[1:]
    files = built() if argv == ["--built"] else [Path(a) for a in argv]
    if not files and argv != ["--built"]:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    failed = False
    for path in files:
        try:
            found = list(seams(path.read_bytes(), path.name))
        except (OSError, zipfile.BadZipFile) as error:
            print(f"check-tunnel-seam: cannot read {path}: {error}", file=sys.stderr)
            failed = True
            continue
        if expect and not found:
            print(f"check-tunnel-seam: {path} was built for the Access fixture but holds no seam", file=sys.stderr)
            failed = True
        elif not expect and found:
            print(f"check-tunnel-seam: {path} holds the Cloudflare Access test seam, which must never ship:", file=sys.stderr)
            for where in found[:5]:
                print(f"  {where}", file=sys.stderr)
            print("  Build it again without --access-fixture or -Pomniterm.tunnelAar.", file=sys.stderr)
            failed = True
    if not failed:
        print(f"check-tunnel-seam: {len(files)} file(s) {'hold the fixture seam' if expect else 'free of the Access test seam'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
