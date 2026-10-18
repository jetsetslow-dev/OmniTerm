import 'package:flutter/material.dart';

import 'colors.dart';
import 'typography.dart';

/// Which colour scheme the app renders in. Mirrors the flags `MyApplicationTheme` took in
/// `ui/theme/Theme.kt` (`darkTheme` / `amoled` / `highContrast` / `dynamicColor`), collapsed into a
/// single enum because they were always resolved by one `when` chain in priority order.
enum OmniThemeMode { system, light, dark, amoled, highContrastDark, highContrastLight, dynamic }

/// Compose's `background` colour role has no direct equivalent in Flutter's [ColorScheme] (it was
/// deprecated in favour of `surface`). The legacy themes set `background` and `surface` to
/// *different* tokens — bg0 vs bg1 — so the distinction is preserved by carrying `background`
/// separately into [ThemeData.scaffoldBackgroundColor].
typedef _Scheme = ({ColorScheme scheme, Color background});

// OmniTerm dark scheme — maps the design tokens onto Material 3 colour roles so every screen
// (cards, bars, chips, buttons) picks up the dark cyberpunk palette automatically.
const _dark = (
  background: OmniColors.bg0,
  scheme: ColorScheme.dark(
    primary: OmniColors.cyan,
    onPrimary: OmniColors.bg0,
    primaryContainer: OmniColors.cyanDim,
    onPrimaryContainer: OmniColors.cyan,
    secondary: OmniColors.purple,
    onSecondary: OmniColors.bg0,
    secondaryContainer: OmniColors.purpleDim,
    onSecondaryContainer: OmniColors.purple,
    tertiary: OmniColors.amber,
    onTertiary: OmniColors.bg0,
    surface: OmniColors.bg1,
    onSurface: OmniColors.textPrimary,
    surfaceContainerLowest: OmniColors.bg0,
    surfaceContainerLow: OmniColors.bg1,
    surfaceContainer: OmniColors.bg2,
    surfaceContainerHigh: OmniColors.bg3,
    surfaceContainerHighest: OmniColors.bg3,
    // Brighter than the raw OmniTerm textSecondary token so secondary text clears AA contrast
    // on AMOLED black.
    onSurfaceVariant: Color(0xFF8FA2BC),
    error: OmniColors.red,
    onError: OmniColors.bg0,
    outline: OmniColors.border,
    outlineVariant: OmniColors.border,
    // Roles Kotlin leaves to Compose's darkColorScheme defaults (Material3 1.4.0 baseline).
    tertiaryContainer: Color(0xFF633B48),
    onTertiaryContainer: Color(0xFFFFD8E4),
    inversePrimary: Color(0xFF6750A4),
    inverseSurface: Color(0xFFE6E0E9),
    onInverseSurface: Color(0xFF322F35),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    scrim: Color(0xFF000000),
    surfaceBright: Color(0xFF3B383E),
    surfaceDim: Color(0xFF141218),
    primaryFixed: Color(0xFFEADDFF),
    primaryFixedDim: Color(0xFFD0BCFF),
    onPrimaryFixed: Color(0xFF21005D),
    onPrimaryFixedVariant: Color(0xFF4F378B),
    secondaryFixed: Color(0xFFE8DEF8),
    secondaryFixedDim: Color(0xFFCCC2DC),
    onSecondaryFixed: Color(0xFF1D192B),
    onSecondaryFixedVariant: Color(0xFF4A4458),
    tertiaryFixed: Color(0xFFFFD8E4),
    tertiaryFixedDim: Color(0xFFEFB8C8),
    onTertiaryFixed: Color(0xFF31111D),
    onTertiaryFixedVariant: Color(0xFF633B48),
  ),
);

// OmniTerm light scheme — same accent identity (cyan/purple/amber) tuned for light surfaces.
const _light = (
  background: Color(0xFFF6F8FB),
  scheme: ColorScheme.light(
    primary: Color(0xFF0091A7),
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFB3EBF2),
    onPrimaryContainer: Color(0xFF00363F),
    secondary: Color(0xFF8E24AA),
    onSecondary: Colors.white,
    tertiary: Color(0xFFB26A00),
    onTertiary: Colors.white,
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF1A1F2B),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF1F4F8),
    surfaceContainer: Color(0xFFEDF1F6),
    surfaceContainerHigh: Color(0xFFE6EAF0),
    surfaceContainerHighest: Color(0xFFDFE4EC),
    onSurfaceVariant: Color(0xFF4A5568),
    error: Color(0xFFD32F2F),
    onError: Colors.white,
    outline: Color(0xFFC2CAD6),
    outlineVariant: Color(0xFFD7DDE6),
    // Roles Kotlin leaves to Compose's lightColorScheme defaults (Material3 1.4.0 baseline
    // tokens). Flutter would otherwise fall back to secondary/error/onSurface for them, which is
    // why selected chips and segments rendered solid purple instead of Compose's lavender.
    secondaryContainer: Color(0xFFE8DEF8),
    onSecondaryContainer: Color(0xFF1D192B),
    tertiaryContainer: Color(0xFFFFD8E4),
    onTertiaryContainer: Color(0xFF31111D),
    inversePrimary: Color(0xFFD0BCFF),
    inverseSurface: Color(0xFF322F35),
    onInverseSurface: Color(0xFFF5EFF7),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    scrim: Color(0xFF000000),
    surfaceBright: Color(0xFFFEF7FF),
    surfaceDim: Color(0xFFDED8E1),
    primaryFixed: Color(0xFFEADDFF),
    primaryFixedDim: Color(0xFFD0BCFF),
    onPrimaryFixed: Color(0xFF21005D),
    onPrimaryFixedVariant: Color(0xFF4F378B),
    secondaryFixed: Color(0xFFE8DEF8),
    secondaryFixedDim: Color(0xFFCCC2DC),
    onSecondaryFixed: Color(0xFF1D192B),
    onSecondaryFixedVariant: Color(0xFF4A4458),
    tertiaryFixed: Color(0xFFFFD8E4),
    tertiaryFixedDim: Color(0xFFEFB8C8),
    onTertiaryFixed: Color(0xFF31111D),
    onTertiaryFixedVariant: Color(0xFF633B48),
  ),
);

// AMOLED variant of the OmniTerm dark scheme: every background/surface role is pure black so OLED
// pixels switch fully off. Element separation comes from the (kept, slightly brightened) borders
// and the accent colours — without them a pure-black UI collapses into a featureless void. Same
// accent identity (cyan/purple/amber) and text colours as the dark scheme.
const _amoled = (
  background: Colors.black,
  scheme: ColorScheme.dark(
    primary: OmniColors.cyan,
    onPrimary: Colors.black,
    primaryContainer: OmniColors.cyanDim,
    onPrimaryContainer: OmniColors.cyan,
    secondary: OmniColors.purple,
    onSecondary: Colors.black,
    secondaryContainer: OmniColors.purpleDim,
    onSecondaryContainer: OmniColors.purple,
    tertiary: OmniColors.amber,
    onTertiary: Colors.black,
    surface: Colors.black,
    onSurface: OmniColors.textPrimary,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: Colors.black,
    surfaceContainer: Colors.black,
    surfaceContainerHigh: Colors.black,
    surfaceContainerHighest: Colors.black,
    onSurfaceVariant: Color(0xFF8FA2BC),
    error: OmniColors.red,
    onError: Colors.black,
    // Brighter than the standard border so cards/dividers stay visible against pure black.
    outline: OmniColors.borderHi,
    outlineVariant: OmniColors.border,
    // Roles Kotlin leaves to Compose's darkColorScheme defaults (Material3 1.4.0 baseline).
    tertiaryContainer: Color(0xFF633B48),
    onTertiaryContainer: Color(0xFFFFD8E4),
    inversePrimary: Color(0xFF6750A4),
    inverseSurface: Color(0xFFE6E0E9),
    onInverseSurface: Color(0xFF322F35),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    scrim: Color(0xFF000000),
    surfaceBright: Color(0xFF3B383E),
    surfaceDim: Color(0xFF141218),
    primaryFixed: Color(0xFFEADDFF),
    primaryFixedDim: Color(0xFFD0BCFF),
    onPrimaryFixed: Color(0xFF21005D),
    onPrimaryFixedVariant: Color(0xFF4F378B),
    secondaryFixed: Color(0xFFE8DEF8),
    secondaryFixedDim: Color(0xFFCCC2DC),
    onSecondaryFixed: Color(0xFF1D192B),
    onSecondaryFixedVariant: Color(0xFF4A4458),
    tertiaryFixed: Color(0xFFFFD8E4),
    tertiaryFixedDim: Color(0xFFEFB8C8),
    onTertiaryFixed: Color(0xFF31111D),
    onTertiaryFixedVariant: Color(0xFF633B48),
  ),
);

const _highContrastDark = (
  background: Colors.black,
  scheme: ColorScheme.dark(
    primary: Color(0xFF00FFFF),
    onPrimary: Colors.black,
    primaryContainer: Color(0xFF005555),
    onPrimaryContainer: Color(0xFF00FFFF),
    secondary: Color(0xFFFF00FF),
    onSecondary: Colors.black,
    surface: Colors.black,
    onSurface: Colors.white,
    surfaceContainerHighest: Color(0xFF222222),
    onSurfaceVariant: Colors.white,
    error: Colors.red,
    onError: Colors.black,
    outline: Colors.white,
    outlineVariant: Colors.white,
    // Everything else is Compose's darkColorScheme default (Material3 1.4.0 baseline).
    secondaryContainer: Color(0xFF4A4458),
    onSecondaryContainer: Color(0xFFE8DEF8),
    tertiary: Color(0xFFEFB8C8),
    onTertiary: Color(0xFF492532),
    surfaceContainerLowest: Color(0xFF0F0D13),
    surfaceContainerLow: Color(0xFF1D1B20),
    surfaceContainer: Color(0xFF211F26),
    surfaceContainerHigh: Color(0xFF2B2930),
    tertiaryContainer: Color(0xFF633B48),
    onTertiaryContainer: Color(0xFFFFD8E4),
    inversePrimary: Color(0xFF6750A4),
    inverseSurface: Color(0xFFE6E0E9),
    onInverseSurface: Color(0xFF322F35),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    scrim: Color(0xFF000000),
    surfaceBright: Color(0xFF3B383E),
    surfaceDim: Color(0xFF141218),
    primaryFixed: Color(0xFFEADDFF),
    primaryFixedDim: Color(0xFFD0BCFF),
    onPrimaryFixed: Color(0xFF21005D),
    onPrimaryFixedVariant: Color(0xFF4F378B),
    secondaryFixed: Color(0xFFE8DEF8),
    secondaryFixedDim: Color(0xFFCCC2DC),
    onSecondaryFixed: Color(0xFF1D192B),
    onSecondaryFixedVariant: Color(0xFF4A4458),
    tertiaryFixed: Color(0xFFFFD8E4),
    tertiaryFixedDim: Color(0xFFEFB8C8),
    onTertiaryFixed: Color(0xFF31111D),
    onTertiaryFixedVariant: Color(0xFF633B48),
  ),
);

const _highContrastLight = (
  background: Colors.white,
  scheme: ColorScheme.light(
    primary: Color(0xFF0000EE),
    onPrimary: Colors.white,
    secondary: Color(0xFF5500AA),
    onSecondary: Colors.white,
    surface: Colors.white,
    onSurface: Colors.black,
    surfaceContainerHighest: Color(0xFFEEEEEE),
    onSurfaceVariant: Colors.black,
    error: Color(0xFFCC0000),
    onError: Colors.white,
    outline: Colors.black,
    outlineVariant: Colors.black,
    // Everything else is Compose's lightColorScheme default (Material3 1.4.0 baseline).
    primaryContainer: Color(0xFFEADDFF),
    onPrimaryContainer: Color(0xFF21005D),
    secondaryContainer: Color(0xFFE8DEF8),
    onSecondaryContainer: Color(0xFF1D192B),
    tertiary: Color(0xFF7D5260),
    onTertiary: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F2FA),
    surfaceContainer: Color(0xFFF3EDF7),
    surfaceContainerHigh: Color(0xFFECE6F0),
    tertiaryContainer: Color(0xFFFFD8E4),
    onTertiaryContainer: Color(0xFF31111D),
    inversePrimary: Color(0xFFD0BCFF),
    inverseSurface: Color(0xFF322F35),
    onInverseSurface: Color(0xFFF5EFF7),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    scrim: Color(0xFF000000),
    surfaceBright: Color(0xFFFEF7FF),
    surfaceDim: Color(0xFFDED8E1),
    primaryFixed: Color(0xFFEADDFF),
    primaryFixedDim: Color(0xFFD0BCFF),
    onPrimaryFixed: Color(0xFF21005D),
    onPrimaryFixedVariant: Color(0xFF4F378B),
    secondaryFixed: Color(0xFFE8DEF8),
    secondaryFixedDim: Color(0xFFCCC2DC),
    onSecondaryFixed: Color(0xFF1D192B),
    onSecondaryFixedVariant: Color(0xFF4A4458),
    tertiaryFixed: Color(0xFFFFD8E4),
    tertiaryFixedDim: Color(0xFFEFB8C8),
    onTertiaryFixed: Color(0xFF31111D),
    onTertiaryFixedVariant: Color(0xFF633B48),
  ),
);

/// Resolve the scheme exactly as the Compose `when` chain did, in the same priority order:
/// dynamic → high contrast → amoled → dark → light.
_Scheme _resolve(OmniThemeMode mode, Brightness platformBrightness, ColorScheme? dynamicScheme) {
  final systemDark = platformBrightness == Brightness.dark;
  return switch (mode) {
    // Dynamic colour is Android 12+ only; elsewhere (and on iOS) it degrades to the app palette,
    // which is why the fallback is the ordinary dark/light scheme rather than an error.
    OmniThemeMode.dynamic when dynamicScheme != null => (
      scheme: dynamicScheme,
      background: dynamicScheme.surface,
    ),
    OmniThemeMode.dynamic => systemDark ? _dark : _light,
    OmniThemeMode.highContrastDark => _highContrastDark,
    OmniThemeMode.highContrastLight => _highContrastLight,
    OmniThemeMode.amoled => _amoled,
    OmniThemeMode.dark => _dark,
    OmniThemeMode.light => _light,
    OmniThemeMode.system => systemDark ? _dark : _light,
  };
}

/// Which mode the saved preferences select, in Kotlin's priority order.
///
/// Ported from the `when` chain in `MyApplicationTheme` (`ui/theme/Theme.kt:159`). Pure so the
/// precedence can be tested without pumping a widget tree — and precedence is the whole substance
/// here: the two flags overlap, and picking the wrong winner is invisible in code review.
///
/// **High contrast outranks AMOLED.** They both change dark mode, and only one can win. AMOLED is a
/// preference about battery and taste; high contrast is an accessibility need, and a user who has
/// asked for legible colours must not have them overridden by a black-background option they set
/// months earlier and forgot.
OmniThemeMode themeModeFor({
  required bool isDark,
  required bool highContrast,
  required bool amoled,
}) {
  if (highContrast) {
    return isDark ? OmniThemeMode.highContrastDark : OmniThemeMode.highContrastLight;
  }
  if (isDark) return amoled ? OmniThemeMode.amoled : OmniThemeMode.dark;
  return OmniThemeMode.light;
}

/// Builds the app [ThemeData]. [dynamicScheme] is the platform-provided scheme (Android 12+
/// Material You) or null where unavailable.
ThemeData omniTheme(
  OmniThemeMode mode,
  Brightness platformBrightness, {
  ColorScheme? dynamicScheme,
}) {
  final resolved = _resolve(mode, platformBrightness, dynamicScheme);
  final scheme = resolved.scheme;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: resolved.background,
    textTheme: omniTextTheme(base.textTheme),
    // Compose's FilterChip (FilterChipTokens, Material3 1.4.0): 32dp tall, 8dp corners, the label
    // 16dp from each edge, LabelLarge text, a 1dp outline-variant border only while unselected,
    // and no checkmark unless the caller passes an icon. Flutter's chip adds a checkmark and a
    // taller box by default, which is why selected chips looked different from Kotlin's.
    chipTheme: base.chipTheme.copyWith(
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: WidgetStateBorderSide.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? BorderSide.none
            : BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}
