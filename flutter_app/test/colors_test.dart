import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/theme/colors.dart';

/// The palette is a compatibility surface, not a style choice: [OmniColors.hostColor] derives a
/// saved host's accent from its name, so any drift in the literals, the ordering of the host
/// colours, or the summing algorithm silently recolours every host that already exists on a user's
/// device. The expectations below are computed from the Kotlin original in `ui/theme/Color.kt`.
void main() {
  group('palette literals', () {
    test('match the design tokens exactly', () {
      // Spot-check the tokens the whole UI keys off; a typo here is invisible until it ships.
      expect(OmniColors.bg0, const Color(0xFF000000));
      expect(OmniColors.bg1, const Color(0xFF0A0E15));
      expect(OmniColors.bg2, const Color(0xFF101622));
      expect(OmniColors.bg3, const Color(0xFF161D2E));
      expect(OmniColors.bg4, const Color(0xFF1C2438));
      expect(OmniColors.border, const Color(0xFF1E2D44));
      expect(OmniColors.borderHi, const Color(0xFF2A3F60));
      expect(OmniColors.cyan, const Color(0xFF00E5FF));
      expect(OmniColors.green, const Color(0xFF00E676));
      expect(OmniColors.amber, const Color(0xFFFFAB00));
      expect(OmniColors.red, const Color(0xFFFF1744));
      expect(OmniColors.purple, const Color(0xFFD500F9));
      expect(OmniColors.orange, const Color(0xFFFF6D00));
      expect(OmniColors.textPrimary, const Color(0xFFC8D4E8));
      expect(OmniColors.textSecondary, const Color(0xFF56708A));
      expect(OmniColors.textMuted, const Color(0xFF2C3E52));
    });
  });

  group('hostColor', () {
    test('reproduces the Kotlin sum-of-code-units mapping', () {
      // Expected values computed from `name.sumOf { it.code } % 6` over
      // [cyan, amber, orange, green, red, purple].
      expect(OmniColors.hostColor('web'), OmniColors.cyan); // sum 318
      expect(OmniColors.hostColor('db'), OmniColors.cyan); // sum 198
      expect(OmniColors.hostColor('prod-01'), OmniColors.green); // sum 579
      expect(OmniColors.hostColor('nas'), OmniColors.red); // sum 322
      expect(OmniColors.hostColor('pi'), OmniColors.amber); // sum 217
      expect(OmniColors.hostColor('router'), OmniColors.amber); // sum 673
      expect(OmniColors.hostColor('A'), OmniColors.purple); // sum 65
      expect(OmniColors.hostColor('homelab'), OmniColors.orange); // sum 728
    });

    test('sums UTF-16 code units, so non-ASCII names match Kotlin', () {
      // Kotlin's Char.code is a UTF-16 code unit, which is what String.codeUnits yields.
      // Summing runes instead would diverge for names outside the BMP.
      expect(OmniColors.hostColor('été'), OmniColors.cyan); // sum 582
    });

    test('empty name short-circuits to cyan', () {
      expect(OmniColors.hostColor(''), OmniColors.cyan);
    });

    test('only ever returns one of the six host colours', () {
      // Not `const`: Color overrides ==, which Dart forbids in a constant set.
      final allowed = {
        OmniColors.cyan,
        OmniColors.amber,
        OmniColors.orange,
        OmniColors.green,
        OmniColors.red,
        OmniColors.purple,
      };
      for (var i = 0; i < 200; i++) {
        expect(allowed, contains(OmniColors.hostColor('host-$i')));
      }
    });
  });

  group('serverAccent', () {
    test('an explicit stored colour wins over the derived one', () {
      expect(OmniColors.serverAccent('Purple', 'web'), OmniColors.purple);
      expect(OmniColors.serverAccent('Green', 'web'), OmniColors.green);
    });

    test('matching is case-insensitive', () {
      expect(OmniColors.serverAccent('purple', 'web'), OmniColors.purple);
      expect(OmniColors.serverAccent('PURPLE', 'web'), OmniColors.purple);
    });

    test('"Default" and unknown names fall back to the derived colour', () {
      expect(OmniColors.serverAccent('Default', 'prod-01'), OmniColors.green);
      expect(OmniColors.serverAccent('Chartreuse', 'prod-01'), OmniColors.green);
    });

    test('exposes exactly the six user-selectable accents for the picker', () {
      expect(OmniColors.namedColors.map((e) => e.$1).toList(), [
        'Cyan',
        'Green',
        'Amber',
        'Orange',
        'Red',
        'Purple',
      ]);
    });
  });
}
