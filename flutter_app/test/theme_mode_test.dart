import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/theme/theme.dart';

/// Which theme the saved preferences select, ported from the `when` chain in `MyApplicationTheme`
/// (`ui/theme/Theme.kt:159`).
///
/// The high-contrast schemes were fully defined in Flutter and **never selected**: `main.dart` chose
/// between light, dark and AMOLED only, so the accessibility toggle in Settings was persisted,
/// backed up, and inert.
void main() {
  group('themeModeFor', () {
    test('the ordinary pair', () {
      expect(themeModeFor(isDark: false, highContrast: false, amoled: false), OmniThemeMode.light);
      expect(themeModeFor(isDark: true, highContrast: false, amoled: false), OmniThemeMode.dark);
    });

    test('AMOLED applies in dark mode only', () {
      expect(themeModeFor(isDark: true, highContrast: false, amoled: true), OmniThemeMode.amoled);
      // Pure-black surfaces in light mode would be neither AMOLED nor light.
      expect(themeModeFor(isDark: false, highContrast: false, amoled: true), OmniThemeMode.light);
    });

    test('high contrast is selected in both brightnesses', () {
      expect(
        themeModeFor(isDark: true, highContrast: true, amoled: false),
        OmniThemeMode.highContrastDark,
      );
      expect(
        themeModeFor(isDark: false, highContrast: true, amoled: false),
        OmniThemeMode.highContrastLight,
      );
    });

    test('high contrast outranks AMOLED', () {
      // Both change dark mode and only one can win. AMOLED is about battery and taste; high contrast
      // is an accessibility need, and it must not be overridden by a black-background option the
      // user set months earlier and forgot.
      expect(
        themeModeFor(isDark: true, highContrast: true, amoled: true),
        OmniThemeMode.highContrastDark,
      );
    });

    test('high contrast in light mode ignores AMOLED entirely', () {
      expect(
        themeModeFor(isDark: false, highContrast: true, amoled: true),
        OmniThemeMode.highContrastLight,
      );
    });
  });
}
