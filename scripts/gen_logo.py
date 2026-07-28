#!/usr/bin/env python3
"""Synchronize bitmap-only system branding from the approved launcher artwork.

Android's biometric SystemUI loads PackageManager's application icon. The normal launcher icon is
adaptive, while that system surface needs a plain bitmap at a small 32dp size. Each distribution's
checked-in ``ic_launcher.png`` is the approved source of truth (including the OSS badge), so this
script copies it byte-for-byte to ``ic_system_brand.png`` for every density.

It intentionally does not draw or regenerate any artwork. That keeps the biometric logo, launcher,
and store assets anchored to the exact approved design.

Usage:
    python3 scripts/gen_logo.py
"""

from __future__ import annotations

from pathlib import Path
from shutil import copyfile

ROOT = Path(__file__).resolve().parent.parent
DENSITIES = ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
SOURCE_SETS = ("main", "openSource")


def main() -> None:
    print("Synchronizing bitmap system-brand icons...")
    for source_set in SOURCE_SETS:
        for density in DENSITIES:
            icon_dir = ROOT / "app" / "src" / source_set / "res" / f"mipmap-{density}"
            source = icon_dir / "ic_launcher.png"
            destination = icon_dir / "ic_system_brand.png"
            copyfile(source, destination)
            print(f"  wrote {destination.relative_to(ROOT)}")
    print("Done. No launcher artwork was regenerated.")


if __name__ == "__main__":
    main()
