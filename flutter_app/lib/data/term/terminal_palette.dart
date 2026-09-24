/// The xterm 256-colour palette, ported from `buildPalette()` in `data/term/TerminalEmulator.kt`.
///
/// 16 base colours + a 6×6×6 cube + 24 greys, packed ARGB.
library;

/// Standard xterm 256-colour palette.
final List<int> palette256 = _buildPalette();

List<int> _buildPalette() {
  final p = List<int>.filled(256, 0xFF000000);

  // Blue (index 4) and bright blue (index 12) are lifted well above the usual ANSI values: pure-ish
  // blue is very low luminance and reads poorly on the near-black terminal background. The brighter
  // tones keep "blue" identity while staying legible. The other 14 are the standard high-contrast
  // xterm values. These deviations are deliberate and must not be "corrected" to the ANSI defaults.
  const base = <int>[
    0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x5C82FF, 0xCD00CD, 0x00CDCD, 0xE5E5E5, //
    0x4D4D4D, 0xFF4444, 0x4DFF4D, 0xFFFF4D, 0x8AB4FF, 0xFF4DFF, 0x4DFFFF, 0xFFFFFF,
  ];
  for (var i = 0; i < 16; i++) {
    p[i] = 0xFF000000 | base[i];
  }

  var idx = 16;
  const steps = <int>[0, 95, 135, 175, 215, 255];
  for (var r = 0; r < 6; r++) {
    for (var g = 0; g < 6; g++) {
      for (var b = 0; b < 6; b++) {
        p[idx++] = 0xFF000000 | (steps[r] << 16) | (steps[g] << 8) | steps[b];
      }
    }
  }

  for (var i = 0; i < 24; i++) {
    final v = 8 + i * 10;
    p[232 + i] = 0xFF000000 | (v << 16) | (v << 8) | v;
  }

  return p;
}
