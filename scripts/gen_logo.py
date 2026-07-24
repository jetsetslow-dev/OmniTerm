#!/usr/bin/env python3
"""Stamp the openSource-flavor amber corner badge onto the shipped Orbit launcher icons.

The Orbit mark itself (app/src/main/res/mipmap-*/ic_launcher*.png, assets/*.png) is the source of
truth and is NOT regenerated here — it was produced by a one-off script and is now just checked-in
art; hand-tuning a from-scratch recreation to pixel-match it isn't worth the risk of drifting from
the approved design. This script only composites a small amber "</>" badge onto a copy of each
main-flavor PNG to produce the app/src/openSource/res/mipmap-*/ic_launcher*.png variant, so the two
distribution flavors stay visually distinguishable on a home screen with both installed.

This preserves a distinction the pre-Orbit icon had (amber #F59E0B corner badge, bottom-right) that
was lost when the Orbit redesign only regenerated app/src/main and left the openSource mipmap
folders on stale pre-Orbit art.

Usage:
    python3 scripts/gen_logo.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

BADGE_COLOR = (0xF5, 0x9E, 0x0B, 255)  # amber-500, matches the pre-Orbit openSource badge
BADGE_GLYPH_COLOR = (0x1A, 0x12, 0x02, 255)
BADGE_RING_COLOR = (0x08, 0x0C, 0x14, 255)  # thin dark outline so the badge reads over light art

SUPERSAMPLE = 4

DENSITIES = ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
ICON_NAMES = ("ic_launcher.png", "ic_launcher_round.png")
# ic_launcher_fg.png ships larger (2.25x) and is inset by the adaptive-icon XML at render time;
# scale the badge position/size to match so it lands in the same visual corner once inset.
FG_NAME = "ic_launcher_fg.png"
FG_SCALE = 2.25


def render_badge(size: int) -> Image.Image:
    """Render the amber '</>' badge at `size`x`size`, transparent background, supersampled."""
    ss = size * SUPERSAMPLE
    img = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    r = ss / 2
    cx = cy = r
    draw.ellipse([1, 1, ss - 1, ss - 1], fill=BADGE_RING_COLOR)
    inner = ss * 0.46
    draw.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=BADGE_COLOR)

    glyph_w = inner * 1.15
    stroke = max(round(inner * 0.18), 1)
    lx, ly = cx - glyph_w * 0.38, cy
    rx, ry = cx + glyph_w * 0.38, cy
    arm = glyph_w * 0.24
    draw.line([(lx + arm, ly - arm), (lx - arm * 0.15, ly), (lx + arm, ly + arm)],
              fill=BADGE_GLYPH_COLOR, width=stroke, joint="curve")
    draw.line([(rx - arm, ry - arm), (rx + arm * 0.15, ry), (rx - arm, ry + arm)],
              fill=BADGE_GLYPH_COLOR, width=stroke, joint="curve")
    slash_len = glyph_w * 0.55
    draw.line([(cx - slash_len * 0.16, cy + slash_len * 0.5),
               (cx + slash_len * 0.16, cy - slash_len * 0.5)],
              fill=BADGE_GLYPH_COLOR, width=stroke)

    return img.resize((size, size), Image.LANCZOS)


def stamp(icon_path: Path, out_path: Path, *, badge_scale: float, badge_center: tuple[float, float]) -> None:
    icon = Image.open(icon_path).convert("RGBA")
    size = icon.size[0]
    badge_size = round(size * badge_scale)
    badge = render_badge(badge_size)

    cx, cy = badge_center
    x = round(size * cx - badge_size / 2)
    y = round(size * cy - badge_size / 2)

    out = icon.copy()
    out.alpha_composite(badge, (x, y))
    out.save(out_path)


def main() -> None:
    main_res = ROOT / "app/src/main/res"
    open_res = ROOT / "app/src/openSource/res"

    print("Stamping openSource badge onto launcher icons...")
    for density in DENSITIES:
        src_dir = main_res / f"mipmap-{density}"
        dst_dir = open_res / f"mipmap-{density}"
        dst_dir.mkdir(parents=True, exist_ok=True)

        # ic_launcher.png is masked to shapes (squircle/circle/etc.) by the launcher, and
        # ic_launcher_round.png is masked to a full circle — keep the badge's bounding circle
        # inside the unit circle (radius 0.5 around center (0.5,0.5)) with a small margin so it
        # never gets clipped by either mask.
        stamp(src_dir / "ic_launcher.png", dst_dir / "ic_launcher.png",
              badge_scale=0.30, badge_center=(0.7263, 0.7263))
        stamp(src_dir / "ic_launcher_round.png", dst_dir / "ic_launcher_round.png",
              badge_scale=0.30, badge_center=(0.7263, 0.7263))

        # The fg layer is larger and gets inset 18/108 (~16.7%) on each side before display, so
        # its visible canvas is the middle ~72/108 of the bitmap; keep the badge inside that.
        stamp(src_dir / FG_NAME, dst_dir / FG_NAME, badge_scale=0.30 * (72 / 108), badge_center=(0.79, 0.79))

        print(f"  wrote {dst_dir.relative_to(ROOT)}/ ({', '.join((*ICON_NAMES, FG_NAME))})")

    print("Done. Review the diffs, then reinstall the openSource flavor to confirm on-device.")


if __name__ == "__main__":
    main()
