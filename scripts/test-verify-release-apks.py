#!/usr/bin/env python3
"""verify-release-apks.py against small real APKs and a bundle, made with the SDK's aapt2 and
apksigner the way a release has them, and each rule seen failing on a release with one file wrong.
Needs ANDROID_HOME with build tools and a platform, and keytool (the JDK)."""
import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("verify_release_apks", HERE / "verify-release-apks.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)

LABEL, CODE = "v1.2.3-rc.2", 10200302
TOOLS = verify.build_tools(None)
SDK = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
PLATFORMS = sorted(SDK.glob("platforms/*/android.jar"))
if not PLATFORMS:
    raise SystemExit(f"test-verify-release-apks: no platform android.jar under {SDK}/platforms")
ANDROID_JAR = PLATFORMS[-1]


def sh(*command):
    result = subprocess.run([str(c) for c in command], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"test-verify-release-apks: {command[0]} failed: {result.stderr or result.stdout}")


def link(work: Path, out: Path, package: str, code: int, name: str, proto: bool = False):
    manifest = work / "AndroidManifest.xml"
    manifest.write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}">'
                        '<uses-sdk android:minSdkVersion="24" android:targetSdkVersion="37"/><application/></manifest>')
    sh(TOOLS / "aapt2", "link", *(["--proto-format"] if proto else []), "-I", ANDROID_JAR, "--manifest", manifest,
       "--version-code", code, "--version-name", name, "-o", out)


def apk(work: Path, out: Path, abis, key="release", package=verify.APK_PACKAGE, code=CODE, name="1.2.3-rc.2", sign=True):
    unsigned = work / f"{out.name}.unsigned"
    link(work, unsigned, package, code, name)
    with zipfile.ZipFile(unsigned, "a") as z:
        z.writestr("classes.dex", b"dex\n035\x00")
        for abi in abis:
            z.writestr(zipfile.ZipInfo(f"lib/{abi}/libgojni.so"), b"\x7fELF" + abi.encode())
    if not sign:
        shutil.move(unsigned, out)
        return
    sh(TOOLS / "apksigner", "sign", "--ks", work / f"{key}.jks", "--ks-pass", "pass:android", "--ks-key-alias", key,
       "--key-pass", "pass:android", "--out", out, unsigned)
    out.with_name(out.name + ".idsig").unlink(missing_ok=True)


def bundle(work: Path, out: Path, abis, code=CODE, package=verify.BUNDLE_PACKAGE):
    proto = work / "proto.apk"
    link(work, proto, package, code, "1.2.3-rc.2", proto=True)
    with zipfile.ZipFile(proto) as src, zipfile.ZipFile(out, "w") as z:
        z.writestr("base/manifest/AndroidManifest.xml", src.read("AndroidManifest.xml"))
        z.writestr("base/resources.pb", src.read("resources.pb"))
        z.writestr("base/dex/classes.dex", b"dex\n035\x00")
        for abi in abis:
            z.writestr(f"base/lib/{abi}/libgojni.so", b"\x7fELF" + abi.encode())


def run(*args) -> tuple[int, str]:
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        try:
            code = verify.main([*map(str, args)])
        except SystemExit as stop:
            code = stop.code
    return code, err.getvalue()


failures = []


def expect(what, result, want, says=""):
    code, err = result
    if code != want or says not in err:
        failures.append(f"{what}: exit {code}, wanted {want}" + (f" saying '{says}'" if says else "") + f"\n    {err.strip()}")


with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    for key in ("release", "other"):
        sh("keytool", "-genkeypair", "-keystore", work / f"{key}.jks", "-storepass", "android", "-keypass", "android",
           "-alias", key, "-dname", f"CN={key}", "-keyalg", "RSA", "-keysize", "2048", "-validity", "1")
    good = work / "good"
    good.mkdir()
    universal = f"OmniTerm-OpenSource-{LABEL}.apk"
    per_abi = {abi: f"OmniTerm-OpenSource-{LABEL}-{abi}.apk" for abi in verify.ABIS}
    apk(work, good / universal, verify.ABIS)
    for abi, name in per_abi.items():
        apk(work, good / name, [abi])
    bundle(work, work / "good.aab", verify.ABIS)

    def release(case: str, replace: dict) -> Path:
        """The good release with some APKs replaced (by what the callable makes) or removed (None)."""
        folder = work / case
        shutil.copytree(good, folder)
        for name, make in replace.items():
            (folder / name).unlink(missing_ok=True)
            if make:
                make(folder / name)
        return folder

    args = ("--label", LABEL, "--version-code", CODE)
    expect("the release as built", run(*args, "--apks", good, "--bundle", work / "good.aab"), 0)
    expect("APKs alone", run(*args, "--apks", good), 0)
    expect("the bundle alone", run(*args, "--bundle", work / "good.aab"), 0)
    expect("neither", run(*args), 2)

    x86_64 = per_abi["x86_64"]
    cases = [
        ("an APK for another architecture under this one's name", {x86_64: lambda p: apk(work, p, ["arm64-v8a"])},
         "native code for arm64-v8a, expected x86_64"),
        ("an architecture's APK holding every architecture", {x86_64: lambda p: apk(work, p, verify.ABIS)},
         f"{x86_64}: native code for arm64-v8a, armeabi-v7a, x86_64, expected x86_64"),
        ("32-bit x86 back in the universal APK", {universal: lambda p: apk(work, p, [*verify.ABIS, "x86"])},
         "native code for arm64-v8a, armeabi-v7a, x86, x86_64"),
        ("an architecture missing from the universal APK", {universal: lambda p: apk(work, p, ["arm64-v8a", "x86_64"])},
         "native code for arm64-v8a, x86_64, expected"),
        ("an APK without native code", {x86_64: lambda p: apk(work, p, [])}, "native code for nothing"),
        ("an architecture's own version code (release * 10 + 3)", {x86_64: lambda p: apk(work, p, ["x86_64"], code=CODE * 10 + 3)},
         f"({CODE * 10 + 3}), expected {verify.APK_PACKAGE} version 1.2.3-rc.2 ({CODE})"),
        ("an older release's APK", {universal: lambda p: apk(work, p, verify.ABIS, code=CODE - 1, name="1.2.3-rc.1")},
         "version 1.2.3-rc.1"),
        ("the Play package in an APK", {per_abi["arm64-v8a"]: lambda p: apk(work, p, ["arm64-v8a"], package=verify.BUNDLE_PACKAGE)},
         f"{verify.BUNDLE_PACKAGE} version"),
        ("a missing architecture's APK", {x86_64: None}, f"missing {x86_64}"),
        ("an extra 32-bit x86 APK", {f"OmniTerm-OpenSource-{LABEL}-x86.apk": lambda p: apk(work, p, ["x86"])},
         f"unexpected APK OmniTerm-OpenSource-{LABEL}-x86.apk"),
        ("one APK signed by another key", {x86_64: lambda p: apk(work, p, ["x86_64"], key="other")},
         "not all signed by the same certificate"),
        ("an unsigned APK", {x86_64: lambda p: apk(work, p, ["x86_64"], sign=False)}, f"{x86_64}: not signed"),
        ("a file that is no APK", {x86_64: lambda p: p.write_bytes(b"PK\x05\x06" + bytes(18))}, f"{x86_64}: aapt2 cannot read"),
    ]
    for n, (what, replace, says) in enumerate(cases):
        expect(what, run(*args, "--apks", release(f"case{n}", replace)), 1, says)

    for what, make, says in [
        ("32-bit x86 in the bundle", lambda p: bundle(work, p, [*verify.ABIS, "x86"]), "native code for arm64-v8a, armeabi-v7a, x86, x86_64"),
        ("an architecture missing from the bundle", lambda p: bundle(work, p, ["arm64-v8a"]), "native code for arm64-v8a, expected"),
        ("another version code in the bundle", lambda p: bundle(work, p, verify.ABIS, code=CODE + 1), f"({CODE + 1})"),
        ("the open-source package as the bundle", lambda p: bundle(work, p, verify.ABIS, package=verify.APK_PACKAGE), f"{verify.APK_PACKAGE} version"),
        ("a bundle without its manifest", lambda p: zipfile.ZipFile(p, "w").writestr("base/dex/classes.dex", b""), "no base module manifest"),
    ]:
        made = work / "wrong.aab"
        make(made)
        expect(what, run(*args, "--bundle", made), 1, says)
    expect("a missing bundle", run(*args, "--bundle", work / "none.aab"), 1, "missing")
    expect("another release's label", run("--label", "v1.2.3-rc.3", "--version-code", CODE, "--apks", good), 1, f"missing OmniTerm-OpenSource-v1.2.3-rc.3.apk")

if failures:
    print("test-verify-release-apks: failed:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
print(f"test-verify-release-apks: the release as built passes, {len(cases) + 7} wrong ones are refused"
      f" (build tools {TOOLS.name}, {ANDROID_JAR.parent.name})")
