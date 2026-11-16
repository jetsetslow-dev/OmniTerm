#!/usr/bin/env python3
"""check-tunnel-seam.py against small archives shaped like the real ones, each case seen failing."""
import contextlib
import importlib.util
import io
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_tunnel_seam", HERE / "check-tunnel-seam.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def archive(entries: dict) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        for name, body in entries.items():
            z.writestr(name, body)
    return out.getvalue()


def run(*args) -> int:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return check.main(list(args))


failures = []


def expect(name, got, want):
    if got != want:
        failures.append(f"{name}: exit {got}, wanted {want}")


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    clean_jar = archive({"com/jetsetslow/omniterm/gotunnel/omnitunnel/Omnitunnel.class": b"startCloudflareAccess startNebula"})
    seam_jar = archive({"com/jetsetslow/omniterm/gotunnel/omnitunnel/Omnitunnel.class": b"startNebula cloudflareFixture"})
    files = {
        "clean.aar": archive({"classes.jar": clean_jar, "jni/arm64-v8a/libgojni.so": b"omnitunnel.StartCloudflareAccess"}),
        "seam-class.aar": archive({"classes.jar": seam_jar, "jni/arm64-v8a/libgojni.so": b"omnitunnel.StartNebula"}),
        "seam-native.apk": archive({"classes.dex": b"dex", "lib/x86_64/libgojni.so": b"omnitunnel.CloudflareFixture"}),
        "seam-name.aab": archive({"base/lib/arm64-v8a/libgojni.so": b"\x00ssh.access.test\x00"}),
        "clean.apk": archive({"classes.dex": b"dex", "lib/arm64-v8a/libgojni.so": b"omnitunnel.StartNebula"}),
        "broken.apk": b"not an archive",
    }
    for name, body in files.items():
        (root / name).write_bytes(body)
    p = lambda name: str(root / name)
    expect("a clean library", run(p("clean.aar")), 0)
    expect("a clean app", run(p("clean.apk")), 0)
    expect("the seam in classes.jar inside the library", run(p("seam-class.aar")), 1)
    expect("the seam in an app's native library", run(p("seam-native.apk")), 1)
    expect("a fixture name in a bundle", run(p("seam-name.aab")), 1)
    expect("one seam among clean files", run(p("clean.aar"), p("seam-native.apk"), p("clean.apk")), 1)
    expect("a file that is no archive", run(p("broken.apk")), 1)
    expect("the fixture build holds its seam", run("--expect-fixture", p("seam-class.aar")), 0)
    expect("a fixture build without its seam", run("--expect-fixture", p("clean.aar")), 1)
    expect("no file named", run(), 2)

    # --built: the library and the apps Gradle wrote, never the instrumentation test APK.
    check.ROOT = root / "repo"
    (check.ROOT / "tunnel/build").mkdir(parents=True)
    apps = check.ROOT / "app/build/outputs/apk"
    (apps / "openSource/debug").mkdir(parents=True)
    (apps / "androidTest/openSource/debug").mkdir(parents=True)
    (check.ROOT / "tunnel/build/omnitunnel.aar").write_bytes(files["clean.aar"])
    (apps / "androidTest/openSource/debug/app-openSource-debug-androidTest.apk").write_bytes(files["seam-native.apk"])
    (apps / "openSource/debug/app-openSource-debug.apk").write_bytes(files["clean.apk"])
    expect("clean outputs and a test APK that drives the seam", run("--built"), 0)
    (apps / "openSource/debug/app-openSource-debug.apk").write_bytes(files["seam-native.apk"])
    expect("an app built with the fixture library", run("--built"), 1)
    (apps / "openSource/debug/app-openSource-debug.apk").write_bytes(files["clean.apk"])
    (check.ROOT / "tunnel/build/omnitunnel.aar").write_bytes(files["seam-class.aar"])
    expect("the fixture library at the production path", run("--built"), 1)

if failures:
    print("test-check-tunnel-seam: failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
print("test-check-tunnel-seam: passed")
