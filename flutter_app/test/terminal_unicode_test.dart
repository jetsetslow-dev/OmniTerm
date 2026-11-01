import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_snapshot.dart';
import 'package:omniterm/data/term/terminal_unicode.dart';

/// Width is where the port had to diverge: the Kotlin asked the JVM for a code point's Unicode
/// general category, and Dart has no such database, so combining marks come from an explicit table.
/// These tests exist to pin that substitution.
///
/// Getting a width wrong is not cosmetic — the emulator lays out cells by these numbers, so an
/// error shifts every following glyph on the row.
void main() {
  group('codePointWidth', () {
    test('ASCII is one column', () {
      for (final c in ['A', 'z', '0', ' ', '~', '!']) {
        expect(codePointWidth(c.runes.first), 1, reason: c);
      }
    });

    test('CJK is two columns', () {
      expect(codePointWidth('日'.runes.first), 2);
      expect(codePointWidth('本'.runes.first), 2);
      expect(codePointWidth('한'.runes.first), 2); // Hangul syllable
      expect(codePointWidth('中'.runes.first), 2);
    });

    test('emoji are two columns', () {
      expect(codePointWidth('🚀'.runes.first), 2);
      expect(codePointWidth('😀'.runes.first), 2);
    });

    test('regional indicators are two columns each', () {
      expect(codePointWidth(0x1F1EC), 2);
    });

    test('fullwidth forms are two columns', () {
      expect(codePointWidth(0xFF21), 2); // fullwidth A
    });

    test('Latin combining marks are zero columns', () {
      expect(codePointWidth(0x0301), 0, reason: 'combining acute');
      expect(codePointWidth(0x0308), 0, reason: 'combining diaeresis');
      expect(codePointWidth(0x036F), 0);
    });

    test('marks from several scripts are zero columns', () {
      // These are the ranges the JVM category lookup used to cover.
      expect(codePointWidth(0x05B4), 0, reason: 'Hebrew point');
      expect(codePointWidth(0x064B), 0, reason: 'Arabic fathatan');
      expect(codePointWidth(0x093E), 0, reason: 'Devanagari vowel sign');
      expect(codePointWidth(0x0E34), 0, reason: 'Thai vowel sign');
      expect(codePointWidth(0x3099), 0, reason: 'Kana voicing mark');
      expect(codePointWidth(0x1DC0), 0, reason: 'Combining supplement');
      expect(codePointWidth(0x1D165), 0, reason: 'Musical symbol (astral)');
    });

    test('format and bidi controls are zero columns', () {
      for (final cp in [0x00AD, 0x061C, 0x200B, 0x200D, 0x202A, 0x2060, 0xFEFF]) {
        expect(codePointWidth(cp), 0, reason: '0x${cp.toRadixString(16)}');
      }
    });

    test('variation selectors, skin tones and tags are zero columns', () {
      expect(codePointWidth(0xFE0E), 0);
      expect(codePointWidth(0xFE0F), 0);
      expect(codePointWidth(0x1F3FB), 0, reason: 'skin tone modifier');
      expect(codePointWidth(0xE0067), 0, reason: 'tag character');
      expect(codePointWidth(0xE0100), 0, reason: 'variation selector supplement');
    });

    test('Hangul jamo tails are zero columns but the lead is wide', () {
      expect(codePointWidth(0x1100), 2, reason: 'jamo initial');
      expect(codePointWidth(0x1161), 0, reason: 'jamo medial');
    });

    test('ordinary letters outside ASCII stay one column', () {
      expect(codePointWidth('é'.runes.first), 1);
      expect(codePointWidth('ß'.runes.first), 1);
      expect(codePointWidth('я'.runes.first), 1);
      expect(codePointWidth('α'.runes.first), 1);
    });

    test('isCombiningMark agrees with the width rule', () {
      expect(isCombiningMark(0x0301), isTrue);
      expect(isCombiningMark(0x0041), isFalse);
      expect(isCombiningMark(0x1F600), isFalse);
    });
  });

  group('clusterDisplayWidth', () {
    test('an empty cluster is zero', () {
      expect(clusterDisplayWidth(''), 0);
    });

    test('a base plus combining marks stays one column', () {
      // This is the whole point of zero-width marks: "e" + acute must not consume two cells.
      expect(clusterDisplayWidth('é'), 1);
      expect(clusterDisplayWidth('à́̂'), 1);
    });

    test('text presentation forces one column', () {
      // U+FE0E on an otherwise-wide symbol.
      expect(clusterDisplayWidth('❤︎'), 1);
    });

    test('emoji presentation forces two columns', () {
      // U+2764 alone is narrow; with FE0F it is drawn as emoji.
      expect(clusterDisplayWidth('❤️'), 2);
    });

    test('a keycap is two columns', () {
      expect(clusterDisplayWidth('1️⃣'), 2);
    });

    test('a two-indicator flag is two columns, one indicator is also two', () {
      expect(clusterDisplayWidth('\u{1F1EC}\u{1F1E7}'), 2, reason: 'GB flag');
      expect(clusterDisplayWidth('\u{1F1EC}'), 2, reason: 'a lone indicator is still wide');
    });

    test('a ZWJ sequence is two columns', () {
      // Family emoji: several wide code points joined; still one two-column cell.
      expect(clusterDisplayWidth('\u{1F468}‍\u{1F469}‍\u{1F466}'), 2);
    });

    test('an emoji with a skin-tone modifier is two columns', () {
      expect(clusterDisplayWidth('\u{1F44D}\u{1F3FB}'), 2);
    });

    test('a cluster of only zero-width marks still claims one column', () {
      // Never zero: a cell that claims no width would make the row layout inconsistent.
      expect(clusterDisplayWidth('́'), 1);
    });

    test('plain ASCII and CJK clusters keep their base width', () {
      expect(clusterDisplayWidth('A'), 1);
      expect(clusterDisplayWidth('日'), 2);
    });
  });

  group('snapshot types', () {
    test('TermRow.text concatenates its spans', () {
      const row = TermRow([
        TermSpan('hello ', kDefaultFg, kDefaultBg),
        TermSpan('world', kDefaultFg, kDefaultBg, bold: true),
      ]);
      expect(row.text, 'hello world');
      expect(row.softWrap, isFalse);
    });

    test('totalRows defaults to the row count but can be overridden', () {
      const rows = [
        TermRow([TermSpan('x', kDefaultFg, kDefaultBg)]),
      ];
      const windowed = TerminalSnapshot(
        rows: rows,
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
        cols: 80,
      );
      expect(windowed.totalRows, 1);

      const paged = TerminalSnapshot(
        rows: rows,
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
        cols: 80,
        firstRow: 500,
        totalRows: 9000,
      );
      expect(paged.totalRows, 9000, reason: 'a windowed snapshot knows the full document size');
    });

    test('the empty snapshot is inert', () {
      expect(TerminalSnapshot.empty.rows, isEmpty);
      expect(TerminalSnapshot.empty.totalRows, 0);
    });

    test('spans compare by attributes, ignoring glyph caches', () {
      const a = TermSpan('x', kDefaultFg, kDefaultBg, bold: true);
      const b = TermSpan('x', kDefaultFg, kDefaultBg, bold: true);
      const c = TermSpan('x', kDefaultFg, kDefaultBg);
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
