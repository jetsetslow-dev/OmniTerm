import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/term/terminal_palette.dart';
import 'colors.dart';

/// Resolved terminal colours for one persisted Kotlin-compatible theme id.
@immutable
class TerminalPalette {
  const TerminalPalette({
    required this.background,
    required this.foreground,
    required this.cursor,
    this.ansiForeground,
  });

  final Color background;
  final Color foreground;
  final Color cursor;

  /// Optional ANSI-16 replacements for text on a light background.
  final List<int>? ansiForeground;
}

const _lightAnsiForeground = <int>[
  0xFF000000,
  0xFFC42B1C,
  0xFF0E7A0B,
  0xFF8A6A00,
  0xFF0451A5,
  0xFFA1259E,
  0xFF067A8C,
  0xFF555F6E,
  0xFF66707F,
  0xFFD13438,
  0xFF10893E,
  0xFF9A7100,
  0xFF2563EB,
  0xFFB4009E,
  0xFF038387,
  0xFF24292F,
];

/// Resolves the same five palettes as Kotlin's `terminalPalette`.
TerminalPalette terminalPaletteFor(BuildContext context, String id) {
  final scheme = Theme.of(context).colorScheme;
  return switch (id) {
    'solarized_dark' => const TerminalPalette(
      background: Color(0xFF002B36),
      foreground: Color(0xFFEEE8D5),
      cursor: Color(0xFFB58900),
    ),
    'matrix' => const TerminalPalette(
      background: Color(0xFF050805),
      foreground: Color(0xFF8CFF9A),
      cursor: Color(0xFF00FF41),
    ),
    'omni_dark' => const TerminalPalette(
      background: OmniColors.bg0,
      foreground: OmniColors.textPrimary,
      cursor: OmniColors.cyan,
    ),
    'light' => const TerminalPalette(
      background: Colors.white,
      foreground: Color(0xFF111827),
      cursor: Color(0xFF005FCC),
      ansiForeground: _lightAnsiForeground,
    ),
    _ when Theme.of(context).brightness == Brightness.light => TerminalPalette(
      background: Colors.white,
      foreground: const Color(0xFF111827),
      cursor: scheme.primary,
      ansiForeground: _lightAnsiForeground,
    ),
    _ => TerminalPalette(
      background: Theme.of(context).scaffoldBackgroundColor,
      foreground: scheme.onSurface,
      cursor: scheme.primary,
    ),
  };
}

int ansi16Index(int argb) {
  for (var i = 0; i < 16; i++) {
    if (palette256[i] == argb) return i;
  }
  return -1;
}

/// WCAG relative luminance of a packed ARGB colour (alpha ignored).
double terminalRelativeLuminance(int argb) {
  double linear(int channel) {
    final c = channel / 255.0;
    return c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * linear((argb >> 16) & 0xff) +
      0.7152 * linear((argb >> 8) & 0xff) +
      0.0722 * linear(argb & 0xff);
}

double terminalContrastRatio(int first, int second) {
  final a = terminalRelativeLuminance(first);
  final b = terminalRelativeLuminance(second);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

int lerpTerminalArgb(int from, int to, double amount) {
  int channel(int shift) {
    final a = (from >> shift) & 0xff;
    final b = (to >> shift) & 0xff;
    return (a + ((b - a) * amount)).truncate().clamp(0, 255);
  }

  return 0xff000000 | (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

/// Keeps remote-selected colours legible when the local terminal uses a different background.
int ensureTerminalTextLegible(
  int foreground,
  int background, {
  double minimumRatio = 2.5,
}) {
  if (terminalContrastRatio(foreground, background) >= minimumRatio) {
    return foreground;
  }
  final backgroundLuminance = terminalRelativeLuminance(background);
  final towardBlack = (backgroundLuminance + 0.05) / 0.05;
  final towardWhite = 1.05 / (backgroundLuminance + 0.05);
  final target = towardBlack >= towardWhite ? 0xff000000 : 0xffffffff;
  for (final amount in const [0.25, 0.5, 0.75]) {
    final candidate = lerpTerminalArgb(foreground, target, amount);
    if (terminalContrastRatio(candidate, background) >= minimumRatio) {
      return candidate;
    }
  }
  return target;
}
