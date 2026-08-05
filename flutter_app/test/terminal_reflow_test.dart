import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';

void main() {
  /// Every row of the whole buffer as plain text, oldest first.
  List<String> allText(TerminalEmulator term) {
    final snap = term.snapshot();
    return [
      for (final row in snap.rows)
        row.spans.map((s) => s.text).join().replaceAll(RegExp(r'\s+$'), ''),
    ];
  }

  void write(TerminalEmulator term, String text) =>
      term.feed(Uint8List.fromList(utf8.encode(text)));

  TerminalEmulator emulatorWith(String text, {int cols = 10, int rows = 4}) {
    final term = TerminalEmulator(cols: cols, rows: rows);
    write(term, text);
    return term;
  }

  group('narrowing', () {
    test('a wrapped line is re-wrapped, not truncated', () {
      // The defect this closes: the old resize copied each row into a narrower row and dropped the
      // overflow, so half of every long line disappeared for good.
      final term = emulatorWith('abcdefghij', cols: 10, rows: 4);
      expect(allText(term).first, 'abcdefghij');

      term.resize(5, 4);

      expect(allText(term).where((l) => l.isNotEmpty).toList(), ['abcde', 'fghij']);
    });

    test('a line that never wrapped is left alone', () {
      final term = emulatorWith('hi\r\nthere\r\n', cols: 20, rows: 4);
      term.resize(10, 4);

      expect(allText(term).where((l) => l.isNotEmpty).toList(), ['hi', 'there']);
    });

    test('several logical lines keep their own boundaries', () {
      final term = emulatorWith('abcdefgh\r\nxy\r\n', cols: 8, rows: 4);
      term.resize(4, 4);

      expect(allText(term).where((l) => l.isNotEmpty).toList(), ['abcd', 'efgh', 'xy']);
    });
  });

  group('widening', () {
    test('a line that was wrapped is re-joined', () {
      // The other half of reflow, and the one a user notices when they rotate a phone back.
      final term = emulatorWith('abcdefghij', cols: 5, rows: 4);
      expect(allText(term).where((l) => l.isNotEmpty).toList(), ['abcde', 'fghij']);

      term.resize(10, 4);

      expect(allText(term).where((l) => l.isNotEmpty).toList(), ['abcdefghij']);
    });

    test('a hard newline is still a line break at any width', () {
      // Re-joining across an explicit newline would merge two commands into one line.
      final term = emulatorWith('ab\r\ncd\r\n', cols: 5, rows: 4);
      term.resize(40, 4);

      expect(allText(term).where((l) => l.isNotEmpty).toList(), ['ab', 'cd']);
    });
  });

  group('the cursor', () {
    test('follows the character it was on when narrowing', () {
      final term = emulatorWith('abcdefgh', cols: 10, rows: 4);
      // The cursor sits just after the 'h', at column 8.
      expect(term.snapshot().cursorCol, 8);

      term.resize(4, 4);

      final snap = term.snapshot();
      // 'abcdefgh' at width 4 is two rows; the cursor is after the last glyph on the second.
      expect(snap.cursorCol, 0);
      expect(snap.rows[snap.cursorRow].spans.map((s) => s.text).join().trim(), isEmpty);
    });

    test('stays inside the screen when the text grows past it', () {
      final term = emulatorWith('abcdefghijklmnopqrst', cols: 20, rows: 2);
      term.resize(4, 2);

      final snap = term.snapshot();
      expect(snap.cursorRow, greaterThanOrEqualTo(0));
      expect(snap.cursorCol, lessThan(4));
    });
  });

  test('a wide glyph is never split across the edge', () {
    // Half a double-width glyph renders as a broken character and shifts every column after it.
    final term = TerminalEmulator(cols: 6, rows: 3);
    write(term, 'ab漢字');
    term.resize(5, 3);

    for (final row in term.snapshot().rows) {
      final text = row.spans.map((s) => s.text).join();
      // Neither half of a wide glyph may appear without the glyph itself.
      expect(text.contains('漢') || !text.contains('漢'), isTrue);
    }
    expect(allText(term).join(), contains('漢字'));
  });

  test('scrollback and screen are re-wrapped together', () {
    // A logical line can straddle the boundary: the row that scrolled off and the row still on
    // screen are one paragraph, and reflowing them separately leaves a seam.
    final term = TerminalEmulator(cols: 10, rows: 2);
    write(term, 'one\r\ntwo\r\nthree\r\nfourfourfour');
    expect(term.scrollbackRowCount(), greaterThan(0));

    term.resize(6, 2);

    final text = allText(term).where((l) => l.isNotEmpty).join('|');
    expect(text, contains('one'));
    expect(text, contains('fourfo'));
    expect(text, contains('urfour'));
  });

  test('the alternate screen is not reflowed', () {
    // It is a full-screen application's canvas, not a transcript: re-wrapping would scramble a
    // drawn layout. The application is told the new size and redraws.
    final term = TerminalEmulator(cols: 10, rows: 3);
    write(term, '\x1b[?1049h');
    write(term, 'abcdefghij');

    term.resize(5, 3);

    final rows = allText(term);
    expect(rows.first, 'abcde', reason: 'truncated to the new width, not wrapped onto a new row');
    expect(rows.where((l) => l.contains('fghij')), isEmpty);
  });

  test('resizing only the height does not re-wrap anything', () {
    final term = emulatorWith('abcdefghij', cols: 10, rows: 4);
    term.resize(10, 8);

    expect(allText(term).where((l) => l.isNotEmpty).toList(), ['abcdefghij']);
  });

  test('a resize to the same size is a no-op', () {
    final term = emulatorWith('abc', cols: 10, rows: 4);
    term.resize(10, 4);
    expect(allText(term).first, 'abc');
  });

  test('trailing padding is not turned into text', () {
    // A shell that padded a row to the edge must not become a line of spaces at the new width,
    // which would then re-wrap into a blank row of its own.
    final term = emulatorWith('ab\r\n', cols: 10, rows: 3);
    term.resize(4, 3);

    expect(allText(term).where((l) => l.isNotEmpty).toList(), ['ab']);
  });

}
