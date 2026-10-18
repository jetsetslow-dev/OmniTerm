import 'package:flutter/material.dart';

/// OmniTerm type families, mirroring the prototype: Oxanium for the techno display/wordmark,
/// JetBrains Mono for code, hostnames, metrics and the terminal. Body text stays on the system
/// sans for legibility.
///
/// Ported from `ui/theme/Type.kt`. The font binaries are the same files the Android build ships
/// (`app/src/main/res/font/`), copied to `assets/fonts/`.
abstract final class OmniFonts {
  static const mono = 'JetBrainsMono';

  /// Oxanium ships as a variable font (wght 200–800, default 200).
  static const display = 'Oxanium';

  /// The weight every Oxanium use renders at. Kotlin asks for Bold, but Android draws the variable
  /// font's default instance with synthetic emboldening; Flutter instead moves the `wght` axis to
  /// 700, which made the wordmark and titles visibly heavier. Normal weight measures within 5% of
  /// Kotlin's stroke density (device screenshots, Oct 2026), so display text uses it regardless of
  /// the weight Kotlin's source names.
  static const displayWeight = FontWeight.normal;
}

/// Compose's `Typography` overrides only four roles; the rest inherit Material defaults. Flutter's
/// [TextTheme] works the same way, so only those four are specified here.
///
/// Compose expresses sizes in `sp` and Flutter in logical pixels, but both are scaled by the
/// platform text-scale factor, so the numbers carry over unchanged.
TextTheme omniTextTheme(TextTheme base) => base.copyWith(
  bodyLarge: base.bodyLarge?.copyWith(
    fontWeight: FontWeight.normal,
    fontSize: 16,
    height: 24 / 16,
    letterSpacing: 0.5,
  ),
  titleLarge: base.titleLarge?.copyWith(
    fontFamily: OmniFonts.display,
    fontWeight: OmniFonts.displayWeight,
    fontSize: 22,
    height: 28 / 22,
    letterSpacing: 0.5,
  ),
  titleMedium: base.titleMedium?.copyWith(
    fontFamily: OmniFonts.display,
    fontWeight: OmniFonts.displayWeight,
    fontSize: 16,
    height: 22 / 16,
    letterSpacing: 0.5,
  ),
  labelSmall: base.labelSmall?.copyWith(
    fontFamily: OmniFonts.mono,
    fontWeight: FontWeight.w500,
    fontSize: 11,
    height: 16 / 11,
    letterSpacing: 0.5,
  ),
);
