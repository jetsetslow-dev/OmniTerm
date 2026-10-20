import 'package:flutter/material.dart';

/// OmniTerm design-system palette, ported 1:1 from `ui/theme/Color.kt` (itself ported from
/// `nexuscomplete.jsx`, the React prototype).
///
/// The literal ARGB values must not drift: [hostColor] derives a saved host's accent from its
/// name, so changing the palette or its ordering silently recolours every existing host.
abstract final class OmniColors {
  static const bg0 = Color(0xFF000000); // AMOLED black — app/terminal background (pixels off)
  static const bg1 = Color(0xFF0A0E15); // bars (barely lifted off black)
  static const bg2 = Color(0xFF101622); // cards
  static const bg3 = Color(0xFF161D2E); // raised surfaces
  static const bg4 = Color(0xFF1C2438); // controls
  static const border = Color(0xFF1E2D44);
  static const borderHi = Color(0xFF2A3F60);

  static const cyan = Color(0xFF00E5FF);
  static const cyanDim = Color(0xFF00233A);
  static const green = Color(0xFF00E676);
  static const greenDim = Color(0xFF00231A);
  static const amber = Color(0xFFFFAB00);
  static const amberDim = Color(0xFF2A1F00);
  static const red = Color(0xFFFF1744);
  static const redDim = Color(0xFF2A0008);
  static const purple = Color(0xFFD500F9);
  static const purpleDim = Color(0xFF1E0026);
  static const orange = Color(0xFFFF6D00);

  static const textPrimary = Color(0xFFC8D4E8);
  static const textSecondary = Color(0xFF56708A);
  static const textMuted = Color(0xFF2C3E52);

  static const _hostColors = <Color>[cyan, amber, orange, green, red, purple];

  /// Deterministic per-host accent colour, mirroring `hostColor()` in the prototype.
  ///
  /// Kotlin's `name.sumOf { it.code }` sums UTF-16 code units, which is exactly what
  /// [String.codeUnits] yields — so hosts keep the colour they had before the migration.
  static Color hostColor(String name) {
    if (name.isEmpty) return cyan;
    final sum = name.codeUnits.fold<int>(0, (a, b) => a + b);
    return _hostColors[sum % _hostColors.length];
  }

  /// The user-selectable accent names, used by the Add/Edit-host colour picker.
  static const namedColors = <(String, Color)>[
    ('Cyan', cyan),
    ('Green', green),
    ('Amber', amber),
    ('Orange', orange),
    ('Red', red),
    ('Purple', purple),
  ];

  /// Resolve a stored colour name (a script's `color`, a tag's accent) to a [Color].
  ///
  /// Matched case-insensitively because the values on disk are lowercase while the display names
  /// here are capitalised. An unknown name falls back to cyan rather than throwing: a colour is
  /// decoration, and a row with an odd value should still render.
  static Color named(String colorName) {
    for (final (name, color) in namedColors) {
      if (name.toLowerCase() == colorName.toLowerCase()) return color;
    }
    return cyan;
  }

  /// Resolve a server's stored `ServerEntity.serverColor` name to a [Color]. "Default" (or any
  /// unknown value) falls back to the deterministic per-name colour so existing rows still look
  /// sensible, while explicit user choices win.
  static Color serverAccent(String colorName, String fallbackName) {
    for (final (name, color) in namedColors) {
      if (name.toLowerCase() == colorName.toLowerCase()) return color;
    }
    return hostColor(fallbackName);
  }
}
