#!/usr/bin/env python3
"""Drive the Kotlin and Flutter apps through the same screens and compare them pixel for pixel.

Both apps run on one emulator at one density against the same fixture host, so a difference in a
capture is a difference in the apps, not in the data. Navigation is by accessibility text, the same
plan for both apps: when a step cannot be found in one app, that is itself reported (a missing tab,
sub-tab or option), and the sweep continues from the next screen.

Output (in --out): k-<step>.png, f-<step>.png, pair-<step>.png (Kotlin left) and report.md with a
difference score per step, worst first (0 means identical pixels; the status bar is masked), plus a
control-state diff per step: every labelled control's enabled / checked / selected state in each
app, so an option that is greyed out, unchecked or missing in only one app is listed.

Usage:
  scripts/parity/screen-sweep.py --serial emulator-5554 --out artifacts/parity/<stamp>
Prerequisites: both debug apps installed, "Block screenshots" off in each, the fixture host saved in
each with the same name (see scripts/test-hosts.sh), screen awake.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

from PIL import Image, ImageChops, ImageStat

APPS = {
    "k": "com.jetsetslow.omniterm.app.oss",
    "f": "com.jetsetslow.omniterm.app.flutter",
}

# (step name, actions). An action is ("tab", label) for the bottom bar, ("tap", label) for any text
# or description, ("back",), ("swipe_tabs",) to reveal off-screen tabs, or ("wait", seconds).
PLAN = [
    ("servers", [("tab", "Servers"), ("wait", 4)]),
    ("servers-add", [("tab", "Servers"), ("tap", "Add server"), ("wait", 2)]),
    ("fleet-dashboard", [("back",), ("tab", "Fleet"), ("wait", 6)]),
    ("fleet-broadcast", [("tap", "Broadcast"), ("wait", 2)]),
    ("fleet-logs", [("tap", "Logs"), ("wait", 2)]),
    ("monitor-overview", [("tab", "Monitor"), ("wait", 8)]),
    ("monitor-processes", [("tap", "Processes"), ("wait", 5)]),
    ("monitor-services", [("tap", "Services"), ("wait", 5)]),
    ("monitor-logs", [("tap", "Logs"), ("wait", 5)]),
    ("monitor-scripts", [("swipe_tabs",), ("tap", "Scripts"), ("wait", 3)]),
    ("monitor-cron", [("swipe_tabs",), ("tap", "CRON"), ("wait", 5)]),
    ("term", [("tab", "Term"), ("wait", 3)]),
    ("files-bookmarks", [("tab", "Files"), ("tap", "Bookmarks"), ("wait", 3)]),
    ("files-sftp", [("tap", "SFTP"), ("wait", 6)]),
    ("files-shares", [("tap", "Shares"), ("wait", 3)]),
    ("files-transfers", [("tap", "Transfers"), ("wait", 2)]),
    ("containers-stacks", [("tab", "Containers"), ("wait", 10)]),
    ("containers-builder", [("tap", "Builder"), ("wait", 3)]),
    ("containers-images", [("tap", "Images"), ("wait", 5)]),
    ("containers-volumes", [("swipe_tabs",), ("tap", "Volumes"), ("wait", 4)]),
    ("containers-networks", [("swipe_tabs",), ("tap", "Networks"), ("wait", 4)]),
    ("tools", [("tab", "Tools"), ("wait", 2)]),
    ("tools-alerts", [("tap", "Alerts"), ("wait", 3)]),
    ("tools-scripts", [("back",), ("tab", "Tools"), ("tap", "Scripts"), ("wait", 3)]),
    ("tools-network", [("back",), ("tab", "Tools"), ("tap", "Network"), ("wait", 3)]),
    ("tools-auth", [("back",), ("tab", "Tools"), ("tap", "Auth"), ("wait", 3)]),
    ("tools-backup", [("back",), ("tab", "Tools"), ("tap", "backup"), ("wait", 3)]),
    ("tools-health", [("back",), ("tab", "Tools"), ("tap", "Health"), ("wait", 3)]),
    ("tools-settings", [("back",), ("tab", "Tools"), ("tap", "Settings"), ("wait", 3)]),
    ("tools-about", [("back",), ("tab", "Tools"), ("tap", "About"), ("wait", 3)]),
]


class Device:
    def __init__(self, serial):
        self.serial = serial

    def sh(self, *args, check=True):
        return subprocess.run(["adb", "-s", self.serial, "shell", *args], capture_output=True,
                              text=True, check=check, timeout=60).stdout

    def nodes(self):
        self.sh("uiautomator", "dump", "/sdcard/ui.xml", check=False)
        xml = self.sh("cat", "/sdcard/ui.xml", check=False)
        for n in re.findall(r"<node [^>]*>", xml):
            text = (re.search(r' text="([^"]*)"', n) or [0, ""])[1]
            desc = (re.search(r'content-desc="([^"]*)"', n) or [0, ""])[1]
            b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
            if b:
                x1, y1, x2, y2 = map(int, b.groups())
                yield text, desc, ((x1 + x2) // 2, (y1 + y2) // 2), y1

    def tap_label(self, label, bottom_bar=False):
        hits = [(c, y) for t, d, c, y in self.nodes()
                if label.lower() in t.lower() or label.lower() in d.split("&#10;")[0].lower()]
        if bottom_bar:
            hits = [h for h in hits if h[1] > 2000] or hits
        if not hits:
            return False
        (x, y), _ = max(hits, key=lambda h: h[1]) if bottom_bar else hits[0]
        self.sh("input", "tap", str(x), str(y))
        return True

    def controls(self):
        """Labelled controls on screen: label -> (enabled, checked, selected)."""
        self.sh("uiautomator", "dump", "/sdcard/ui.xml", check=False)
        xml = self.sh("cat", "/sdcard/ui.xml", check=False)
        out = {}
        for n in re.findall(r"<node [^>]*>", xml):
            attr = lambda k: (re.search(k + r'="([^"]*)"', n) or [0, ""])[1]
            interactive = "true" in (attr("clickable"), attr("checkable"), attr("long-clickable"))
            label = (attr(" text") or attr("content-desc")).split("&#10;")[0].strip()
            if interactive and label and not re.fullmatch(r"[\d\s:.%/·-]+", label):
                out[label] = (attr("enabled"), attr("checked") if attr("checkable") == "true" else "-",
                              attr("selected"))
        return out

    def screenshot(self, path):
        with open(path, "wb") as out:
            subprocess.run(["adb", "-s", self.serial, "exec-out", "screencap", "-p"], stdout=out,
                           check=True, timeout=60)


def run_app(dev, prefix, package, out):
    missing = []
    dev.sh("am", "force-stop", package)
    dev.sh("monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1", check=False)
    time.sleep(8)
    for name, actions in PLAN:
        ok = True
        for action in actions:
            kind = action[0]
            if kind == "wait":
                time.sleep(action[1])
            elif kind == "back":
                dev.sh("input", "keyevent", "KEYCODE_BACK")
                time.sleep(1)
            elif kind == "swipe_tabs":
                dev.sh("input", "swipe", "900", "480", "200", "480", "300")
                time.sleep(1)
            elif kind in ("tab", "tap"):
                if not dev.tap_label(action[1], bottom_bar=kind == "tab"):
                    ok = False
                    missing.append(f"{name}: '{action[1]}' not found")
                    break
                time.sleep(1.5)
        if ok:
            dev.screenshot(out / f"{prefix}-{name}.png")
            (out / f"{prefix}-{name}.controls.json").write_text(json.dumps(dev.controls(), indent=1))
    dev.sh("am", "force-stop", package)
    return missing


def score(a, b):
    x, y = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if x.size != y.size:
        y = y.resize(x.size)
    # Mask the status bar (clock, icons) — it differs between captures and says nothing about the app.
    for img in (x, y):
        img.paste((0, 0, 0), (0, 0, img.width, int(img.height * 0.045)))
    diff = ImageChops.difference(x, y)
    return sum(ImageStat.Stat(diff).mean) / 3 / 255 * 100, x, y


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serial", default="emulator-5554")
    ap.add_argument("--out", type=pathlib.Path, required=True)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    dev = Device(args.serial)
    missing = {p: run_app(dev, p, pkg, args.out) for p, pkg in APPS.items()}
    rows = []
    for name, _ in PLAN:
        k, f = args.out / f"k-{name}.png", args.out / f"f-{name}.png"
        if not (k.exists() and f.exists()):
            rows.append((float("inf"), name, "capture missing in " + ("Kotlin" if not k.exists() else "Flutter")))
            continue
        s, x, y = score(k, f)
        pair = Image.new("RGB", (x.width * 2 + 20, x.height), "white")
        pair.paste(Image.open(k).convert("RGB"), (0, 0))
        pair.paste(Image.open(f).convert("RGB").resize(x.size), (x.width + 20, 0))
        pair.resize((pair.width // 2, pair.height // 2)).save(args.out / f"pair-{name}.png")
        rows.append((s, name, ""))
    lines = ["# Kotlin ↔ Flutter screen sweep", "", "| step | difference % | note |", "|---|---|---|"]
    for s, name, note in sorted(rows, key=lambda r: -r[0] if r[0] != float("inf") else -1e9):
        lines.append(f"| {name} | {'—' if s == float('inf') else f'{s:.2f}'} | {note} |")
    lines += ["", "## Control state differences (enabled, checked, selected)"]
    for name, _ in PLAN:
        kc, fc = args.out / f"k-{name}.controls.json", args.out / f"f-{name}.controls.json"
        if not (kc.exists() and fc.exists()):
            continue
        k, f = json.loads(kc.read_text()), json.loads(fc.read_text())
        norm = lambda d: {key.lower(): (key, v) for key, v in d.items()}
        kn, fn = norm(k), norm(f)
        diffs = []
        for key in sorted(set(kn) | set(fn)):
            if key not in fn:
                diffs.append(f"Kotlin only: '{kn[key][0]}'")
            elif key not in kn:
                diffs.append(f"Flutter only: '{fn[key][0]}'")
            elif tuple(kn[key][1]) != tuple(fn[key][1]):
                diffs.append(f"'{kn[key][0]}' Kotlin {tuple(kn[key][1])} vs Flutter {tuple(fn[key][1])}")
        if diffs:
            lines += [f"### {name}"] + [f"- {d}" for d in diffs]
    for prefix, items in missing.items():
        if items:
            lines += ["", f"## Navigation failures — {'Kotlin' if prefix == 'k' else 'Flutter'}"]
            lines += [f"- {m}" for m in items]
    (args.out / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
