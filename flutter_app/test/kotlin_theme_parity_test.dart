import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/theme/typography.dart';

/// Roles Kotlin's `lightColorScheme`/`darkColorScheme` leave at Compose's Material3 1.4.0
/// defaults. Flutter's `ColorScheme` would otherwise fall back to `secondary`, which turned every
/// selected chip solid purple instead of Compose's lavender.
void main() {
  test('light scheme uses Compose defaults for roles Kotlin leaves unset', () {
    final scheme = omniTheme(OmniThemeMode.light, Brightness.light).colorScheme;
    expect(scheme.secondaryContainer, const Color(0xFFE8DEF8));
    expect(scheme.onSecondaryContainer, const Color(0xFF1D192B));
    expect(scheme.tertiaryContainer, const Color(0xFFFFD8E4));
    expect(scheme.errorContainer, const Color(0xFFF9DEDC));
    expect(scheme.inverseSurface, const Color(0xFF322F35));
    // Roles Kotlin sets explicitly stay Kotlin's.
    expect(scheme.secondary, const Color(0xFF8E24AA));
    expect(scheme.surfaceContainer, const Color(0xFFEDF1F6));
  });

  test('dark scheme keeps Kotlin\'s purple containers and Compose\'s defaults elsewhere', () {
    final scheme = omniTheme(OmniThemeMode.dark, Brightness.dark).colorScheme;
    expect(scheme.tertiaryContainer, const Color(0xFF633B48));
    expect(scheme.errorContainer, const Color(0xFF8C1D18));
    expect(scheme.inverseSurface, const Color(0xFFE6E0E9));
  });

  test('chips match Compose FilterChip: no checkmark, 8dp corners', () {
    final chips = omniTheme(OmniThemeMode.light, Brightness.light).chipTheme;
    expect(chips.showCheckmark, isFalse);
    expect(chips.shape, RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)));
  });

  test('Oxanium titles render at the weight Kotlin actually draws', () {
    final text = omniTheme(OmniThemeMode.light, Brightness.light).textTheme;
    expect(text.titleLarge!.fontWeight, OmniFonts.displayWeight);
    expect(OmniFonts.displayWeight, FontWeight.normal);
  });
}
