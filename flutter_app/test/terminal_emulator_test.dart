import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';
import 'package:omniterm/data/term/terminal_palette.dart';
import 'package:omniterm/data/term/terminal_snapshot.dart';

/// End-to-end tests: real byte streams in, rendered rows out, exercising decoder → parser →
/// screen model together. This is the level the Kotlin `Terminal*Test.kt` suites work at.
void main() {
  TerminalEmulator emu({int cols = 20, int rows = 5, int scrollback = 100}) =>
      TerminalEmulator(cols: cols, rows: rows, scrollbackLimit: scrollback);

  void write(TerminalEmulator e, String s) => e.feed(Uint8List.fromList(utf8.encode(s)));

  /// Visible rows as plain text, right-trimmed.
  List<String> screen(TerminalEmulator e) {
    final snap = e.snapshot();
    return [
      for (var i = e.scrollbackRowCount(); i < snap.rows.length; i++) snap.rows[i].text.trimRight(),
    ];
  }

  List<String> history(TerminalEmulator e) {
    final snap = e.snapshot();
    return [for (var i = 0; i < e.scrollbackRowCount(); i++) snap.rows[i].text.trimRight()];
  }

  group('printing and wrapping', () {
    test('plain text lands on the first row', () {
      final e = emu()..let((e) => write(e, 'hello'));
      expect(screen(e).first, 'hello');
    });

    test('CR/LF move the cursor as expected', () {
      final e = emu();
      write(e, 'one\r\ntwo');
      expect(screen(e).take(2), ['one', 'two']);
    });

    test('text past the right edge soft-wraps and is marked', () {
      final e = emu(cols: 5);
      write(e, 'abcdefgh');
      expect(screen(e).take(2), ['abcde', 'fgh']);
      // The wrap must be recorded, or copying the scrollback re-inserts a line break the remote
      // never sent.
      expect(e.snapshot().rows.first.softWrap, isTrue);
    });

    test('an explicit newline is not a soft wrap', () {
      final e = emu(cols: 5);
      write(e, 'abc\r\nde');
      expect(e.snapshot().rows.first.softWrap, isFalse);
    });

    test('a wide glyph wraps whole rather than being split', () {
      final e = emu(cols: 3);
      write(e, 'ab日');
      // Only one column remained, which cannot hold a two-column glyph.
      expect(screen(e).take(2), ['ab', '日']);
    });

    test('combining marks attach to the previous cell', () {
      // Written explicitly as the *decomposed* form (e + U+0301) rather than a literal, so editor
      // normalisation cannot silently change what is being tested. The point is that the mark joins
      // the preceding cell instead of claiming a column of its own.
      final e = emu();
      write(e, 'éx');
      final row = screen(e).first;
      expect(row, 'éx');

      final spans = e.snapshot().rows.first.spans;
      expect(spans.first.glyphs, [
        'é',
        'x',
      ], reason: 'two cells, the first holding the composed cluster');
      expect(spans.first.glyphWidths, [1, 1]);
    });

    test('a leading combining mark gets a dotted circle rather than vanishing', () {
      final e = emu();
      write(e, '́');
      expect(screen(e).first, startsWith('◌'));
    });

    test('a ZWJ emoji sequence stays one cluster', () {
      final e = emu();
      write(e, '\u{1F468}‍\u{1F469}‍\u{1F466}');
      final row = e.snapshot().rows[0];
      expect(row.spans.first.glyphs, hasLength(1));
      expect(row.spans.first.glyphWidths.first, 2);
    });
  });

  group('cursor and erase', () {
    test('CUP positions the cursor', () {
      final e = emu();
      write(e, '\x1B[3;5Hx');
      expect(screen(e)[2], '    x');
    });

    test('erase in line clears to the right', () {
      final e = emu();
      write(e, 'abcdef\x1B[1;4H\x1B[K');
      expect(screen(e).first, 'abc');
    });

    test('erase in display clears everything', () {
      final e = emu();
      write(e, 'a\r\nb\r\nc\x1B[2J');
      expect(screen(e).every((r) => r.isEmpty), isTrue);
    });

    test('erase in display mode 3 also clears scrollback', () {
      final e = emu(rows: 2);
      write(e, 'a\r\nb\r\nc\r\nd');
      expect(e.scrollbackRowCount(), greaterThan(0));
      write(e, '\x1B[3J');
      expect(e.scrollbackRowCount(), 0);
    });

    test('backspace moves left without erasing', () {
      final e = emu();
      write(e, 'abc\x08X');
      expect(screen(e).first, 'abX');
    });

    test('tab advances to the next 8-column stop', () {
      final e = emu(cols: 20);
      write(e, 'a\tb');
      expect(screen(e).first, 'a       b');
    });

    test('delete and insert characters shift the row', () {
      final e = emu();
      write(e, 'abcdef\x1B[1;2H\x1B[2P');
      expect(screen(e).first, 'adef');

      final f = emu();
      write(f, 'abc\x1B[1;2H\x1B[2@');
      expect(screen(f).first, 'a  bc');
    });

    test('save and restore cursor round-trips', () {
      final e = emu();
      write(e, '\x1B[2;3H\x1B7\x1B[5;10H\x1B8X');
      expect(screen(e)[1], '  X');
    });

    test('a Kitty keyboard sequence is not mistaken for SCORC', () {
      // CSI >1u carries a parameter, so it must not restore the cursor — doing so is what made a
      // TUI's exit paint over stale rows.
      final e = emu();
      write(e, '\x1B[2;3H\x1B7\x1B[5;10H\x1B[>1uX');
      expect(screen(e)[4], '         X', reason: 'cursor must have stayed at 5;10');
    });
  });

  group('scrolling and scrollback', () {
    test('output past the last row scrolls into history', () {
      final e = emu(rows: 3);
      write(e, 'l1\r\nl2\r\nl3\r\nl4');
      expect(history(e), ['l1']);
      expect(screen(e), ['l2', 'l3', 'l4']);
    });

    test('scrollback is bounded by its limit', () {
      final e = emu(rows: 2, scrollback: 3);
      for (var i = 0; i < 20; i++) {
        write(e, 'line$i\r\n');
      }
      expect(e.scrollbackRowCount(), 3);
      expect(
        e.trimmedRowCount,
        greaterThan(0),
        reason: 'trimmed rows anchor a scrolled-up viewport',
      );
    });

    test('a scroll region confines scrolling', () {
      final e = emu(rows: 5);
      write(e, '\x1B[2;3r'); // region rows 2..3
      write(e, '\x1B[2;1Ha\r\nb\r\nc');
      // Only rows 2-3 scrolled; row 5 is untouched.
      expect(screen(e)[4], isEmpty);
    });

    test('reverse index scrolls down at the top', () {
      final e = emu(rows: 3);
      write(e, 'a\r\nb\x1B[1;1H\x1BM');
      expect(screen(e)[1], 'a');
    });

    test('clearScrollback empties history but keeps the screen', () {
      final e = emu(rows: 2);
      write(e, 'a\r\nb\r\nc');
      expect(e.scrollbackRowCount(), greaterThan(0));
      e.clearScrollback();
      expect(e.scrollbackRowCount(), 0);
      expect(screen(e).last, 'c');
    });
  });

  group('SGR', () {
    test('basic colours map to the palette', () {
      final e = emu();
      write(e, '\x1B[31mred');
      expect(e.snapshot().rows.first.spans.first.fg, palette256[1]);
    });

    test('the deliberately lifted blue is used, not pure ANSI blue', () {
      // Pure blue is unreadable on near-black; the palette lifts it on purpose.
      final e = emu();
      write(e, '\x1B[34mblue');
      expect(e.snapshot().rows.first.spans.first.fg, 0xFF5C82FF);
    });

    test('256-colour and truecolor are parsed', () {
      final e = emu();
      write(e, '\x1B[38;5;196mx');
      expect(e.snapshot().rows.first.spans.first.fg, palette256[196]);

      final f = emu();
      write(f, '\x1B[38;2;10;20;30my');
      expect(f.snapshot().rows.first.spans.first.fg, 0xFF0A141E);
    });

    test('attributes set and clear', () {
      final e = emu();
      write(e, '\x1B[1;3;4;7mx\x1B[22;23;24;27my');
      final spans = e.snapshot().rows.first.spans;
      expect(spans.first.bold, isTrue);
      expect(spans.first.italic, isTrue);
      expect(spans.first.underline, isTrue);
      expect(spans.first.inverse, isTrue);
      expect(spans.last.bold, isFalse);
      expect(spans.last.underline, isFalse);
    });

    test('SGR 0 and a bare CSI m both reset', () {
      final e = emu();
      write(e, '\x1B[1;31ma\x1B[mb');
      expect(e.snapshot().rows.first.spans.last.fg, kDefaultFg);
      expect(e.snapshot().rows.first.spans.last.bold, isFalse);
    });

    test('runs of identical styling collapse into one span', () {
      final e = emu();
      write(e, '\x1B[31mabcdef');
      expect(e.snapshot().rows.first.spans, hasLength(1));
    });
  });

  group('modes', () {
    test('DECCKM and bracketed paste are tracked', () {
      final e = emu();
      expect(e.applicationCursorKeys, isFalse);
      write(e, '\x1B[?1h\x1B[?2004h');
      expect(e.applicationCursorKeys, isTrue);
      expect(e.bracketedPasteMode, isTrue);
      write(e, '\x1B[?1l\x1B[?2004l');
      expect(e.applicationCursorKeys, isFalse);
      expect(e.bracketedPasteMode, isFalse);
    });

    test('cursor visibility is tracked', () {
      final e = emu();
      write(e, '\x1B[?25l');
      expect(e.snapshot().cursorVisible, isFalse);
    });

    test('1049 saves and restores both the screen and the cursor', () {
      final e = emu();
      write(e, 'shell\x1B[3;5H');
      write(e, '\x1B[?1049h'); // enter alt
      expect(e.isAlternateScreenActive, isTrue);
      write(e, 'tui');
      expect(screen(e).first, 'tui');
      write(e, '\x1B[?1049l'); // leave
      expect(e.isAlternateScreenActive, isFalse);
      expect(screen(e).first, 'shell', reason: 'the primary screen must come back intact');
      final snap = e.snapshot();
      expect(snap.cursorRow, 2, reason: 'and the cursor with it');
      expect(snap.cursorCol, 4);
    });

    test('47 switches buffers without touching the cursor', () {
      final e = emu();
      write(e, '\x1B[4;7H');
      write(e, '\x1B[?47h');
      write(e, '\x1B[?47l');
      final snap = e.snapshot();
      // 47 must not restore a cursor — that is 1048's job.
      expect(snap.cursorRow, 0, reason: 'entering alt homed the cursor and 47 leaves it there');
    });

    test('alt-screen output does not enter scrollback by default', () {
      final e = emu(rows: 2);
      write(e, '\x1B[?1049h');
      for (var i = 0; i < 10; i++) {
        write(e, 'x\r\n');
      }
      expect(
        e.scrollbackRowCount(),
        0,
        reason: 'an alt-screen app owns its display and must not pour repaints into history',
      );
    });

    test('tmux-backed sessions can opt into alt-screen scrollback', () {
      final e = emu(rows: 2)..setCaptureAlternateScreenScrollback(true);
      write(e, '\x1B[?1049h');
      for (var i = 0; i < 5; i++) {
        write(e, 'x\r\n');
      }
      expect(e.scrollbackRowCount(), greaterThan(0));
    });
  });

  group('defensive behaviour', () {
    test('unknown sequences are ignored, not printed', () {
      final e = emu();
      write(e, '\x1B[99999ZOK');
      expect(screen(e).first, 'OK');
    });

    test('an OSC title is swallowed', () {
      final e = emu();
      write(e, '\x1B]0;window title\x07visible');
      expect(screen(e).first, 'visible');
    });

    test('binary garbage never throws', () {
      final e = emu();
      final junk = Uint8List.fromList(List.generate(2000, (i) => i % 256));
      expect(() => e.feed(junk), returnsNormally);
      expect(() => e.snapshot(), returnsNormally);
    });

    test('UTF-8 split across feeds is reassembled', () {
      final e = emu();
      final bytes = utf8.encode('日本');
      e.feed(Uint8List.fromList(bytes.sublist(0, 2)));
      e.feed(Uint8List.fromList(bytes.sublist(2)));
      expect(screen(e).first, '日本');
    });

    test('reset returns the emulator to a clean state', () {
      final e = emu();
      write(e, '\x1B[31mtext\r\nmore\x1B[?1h');
      e.reset();
      expect(screen(e).every((r) => r.isEmpty), isTrue);
      expect(e.applicationCursorKeys, isFalse);
      expect(e.scrollbackRowCount(), 0);
    });

    test('ESC c performs a full reset', () {
      final e = emu();
      write(e, 'text\x1Bc');
      expect(screen(e).every((r) => r.isEmpty), isTrue);
    });
  });

  group('snapshot windowing', () {
    test('snapshotRange returns only the requested rows', () {
      final e = emu(rows: 2);
      for (var i = 0; i < 10; i++) {
        write(e, 'l$i\r\n');
      }
      final all = e.snapshot();
      final window = e.snapshotRange(2, 3);
      expect(window.rows, hasLength(3));
      expect(window.firstRow, 2);
      expect(
        window.totalRows,
        all.totalRows,
        reason: 'a windowed snapshot still knows the document size',
      );
    });

    test('an out-of-range window is clamped rather than throwing', () {
      final e = emu();
      expect(() => e.snapshotRange(9999, 10), returnsNormally);
      expect(e.snapshotRange(9999, 10).rows, isEmpty);
    });
  });

  group('resize', () {
    test('content survives a resize and the cursor is clamped', () {
      // The cursor is parked on the last row, so shrinking to three rows pushes the top of the
      // buffer into scrollback — which is what a terminal does, and what this asserted before
      // reflow was implemented was that rows were copied top-down and the cursor merely clamped.
      // "Survives" now means still in the buffer, not still on the screen.
      final e = emu(cols: 20, rows: 5);
      write(e, 'hello\x1B[5;10H');
      e.resize(10, 3);
      expect(e.cols, 10);
      expect(e.rows, 3);
      expect(
        e.snapshot().rows.map((r) => r.spans.map((s) => s.text).join().trimRight()),
        contains('hello'),
      );
      expect(e.snapshot().cursorRow, lessThan(e.snapshot().totalRows));
    });

    test('resizing to the same size is a no-op', () {
      final e = emu(cols: 20, rows: 5);
      write(e, 'x');
      e.resize(20, 5);
      expect(screen(e).first, 'x');
    });

    test('degenerate sizes are clamped to at least 1x1', () {
      final e = emu()..resize(0, -3);
      expect(e.cols, 1);
      expect(e.rows, 1);
    });
  });
}

extension _Let<T> on T {
  T let(void Function(T) block) {
    block(this);
    return this;
  }
}
