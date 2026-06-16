package com.jetsetslow.omniterm.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

import androidx.compose.ui.graphics.Color

// OmniTerm dark scheme — maps the design tokens onto Material 3 colour roles so every screen
// (cards, bars, chips, buttons) picks up the dark cyberpunk palette automatically.
private val DarkColorScheme =
  darkColorScheme(
    primary = OmniColors.cyan,
    onPrimary = OmniColors.bg0,
    primaryContainer = OmniColors.cyanDim,
    onPrimaryContainer = OmniColors.cyan,
    secondary = OmniColors.purple,
    onSecondary = OmniColors.bg0,
    secondaryContainer = OmniColors.purpleDim,
    onSecondaryContainer = OmniColors.purple,
    tertiary = OmniColors.amber,
    onTertiary = OmniColors.bg0,
    background = OmniColors.bg0,
    onBackground = OmniColors.textPrimary,
    surface = OmniColors.bg1,
    onSurface = OmniColors.textPrimary,
    surfaceVariant = OmniColors.bg3,
    // Brighter than the raw OmniTerm textSecondary token so secondary text clears AA contrast on AMOLED black.
    onSurfaceVariant = Color(0xFF8FA2BC),
    surfaceContainerLowest = OmniColors.bg0,
    surfaceContainerLow = OmniColors.bg1,
    surfaceContainer = OmniColors.bg2,
    surfaceContainerHigh = OmniColors.bg3,
    surfaceContainerHighest = OmniColors.bg3,
    error = OmniColors.red,
    onError = OmniColors.bg0,
    outline = OmniColors.border,
    outlineVariant = OmniColors.border,
  )

// OmniTerm light scheme — same accent identity (cyan/purple/amber) tuned for light surfaces.
private val LightColorScheme =
  lightColorScheme(
    primary = Color(0xFF0091A7),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFB3EBF2),
    onPrimaryContainer = Color(0xFF00363F),
    secondary = Color(0xFF8E24AA),
    onSecondary = Color.White,
    tertiary = Color(0xFFB26A00),
    onTertiary = Color.White,
    background = Color(0xFFF6F8FB),
    onBackground = Color(0xFF1A1F2B),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1A1F2B),
    surfaceVariant = Color(0xFFE6EAF0),
    onSurfaceVariant = Color(0xFF4A5568),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF1F4F8),
    surfaceContainer = Color(0xFFEDF1F6),
    surfaceContainerHigh = Color(0xFFE6EAF0),
    surfaceContainerHighest = Color(0xFFDFE4EC),
    error = Color(0xFFD32F2F),
    onError = Color.White,
    outline = Color(0xFFC2CAD6),
    outlineVariant = Color(0xFFD7DDE6),
  )

private val HighContrastDarkColorScheme =
  darkColorScheme(
    primary = Color(0xFF00FFFF),
    onPrimary = Color.Black,
    primaryContainer = Color(0xFF005555),
    onPrimaryContainer = Color(0xFF00FFFF),
    secondary = Color(0xFFFF00FF),
    onSecondary = Color.Black,
    background = Color.Black,
    onBackground = Color.White,
    surface = Color.Black,
    onSurface = Color.White,
    surfaceVariant = Color(0xFF222222),
    onSurfaceVariant = Color.White,
    error = Color.Red,
    onError = Color.Black,
    outline = Color.White,
    outlineVariant = Color.White,
  )

private val HighContrastLightColorScheme =
  lightColorScheme(
    primary = Color(0xFF0000EE),
    onPrimary = Color.White,
    secondary = Color(0xFF5500AA),
    onSecondary = Color.White,
    background = Color.White,
    onBackground = Color.Black,
    surface = Color.White,
    onSurface = Color.Black,
    surfaceVariant = Color(0xFFEEEEEE),
    onSurfaceVariant = Color.Black,
    error = Color(0xFFCC0000),
    onError = Color.White,
    outline = Color.Black,
    outlineVariant = Color.Black,
  )

@Composable
fun MyApplicationTheme(
  darkTheme: Boolean = isSystemInDarkTheme(),
  // Dynamic color is available on Android 12+
  dynamicColor: Boolean = false,
  highContrast: Boolean = false,
  /** App-wide font scale multiplier from the Settings "Text size" option. */
  fontScale: Float = 1f,
  content: @Composable () -> Unit,
) {
  val colorScheme =
    when {
      dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
        val context = LocalContext.current
        if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
      }

      highContrast && darkTheme -> HighContrastDarkColorScheme
      highContrast && !darkTheme -> HighContrastLightColorScheme
      darkTheme -> DarkColorScheme
      else -> LightColorScheme
    }

  // Override the density's fontScale so every `.sp` (including each screen's explicit sizes)
  // scales uniformly with the user's choice.
  val base = androidx.compose.ui.platform.LocalDensity.current
  val scaled = androidx.compose.ui.unit.Density(base.density, base.fontScale * fontScale)
  androidx.compose.runtime.CompositionLocalProvider(
    androidx.compose.ui.platform.LocalDensity provides scaled
  ) {
    MaterialTheme(colorScheme = colorScheme, typography = Typography, content = content)
  }
}
