import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_cell.dart';
import 'package:omniterm/data/term/terminal_parser.dart';
import 'package:omniterm/data/term/terminal_snapshot.dart';

/// Records what the parser recognised, so sequence handling can be asserted without a screen.
class RecordingSink implements TerminalSink {
  final List<String> events = [];

  @override
  void print(int codePoint) => events.add('print:${String.fromCharCode(codePoint)}');

  @override
  void execute(int control) =>
      events.add('exec:0x${control.toRadixString(16).padLeft(2, '0')}');

  @override
  void csiDispatch(String params, {required bool private, required String finalByte}) =>
      events.add('csi:${private ? '?' : ''}$params$finalByte');

  @override
  void escDispatch(String finalByte) => events.add('esc:$finalByte');

  @override
  void fullReset() => events.add('reset');
}

/// Feeds a string as code points, the way the UTF-8 decoder hands them over.
List<String> parse(String input) {
  final sink = RecordingSink();
  final parser = TerminalParser(sink);
  for (final rune in input.runes) {
    parser.processCodePoint(rune);
  }
  return sink.events;
}

void main() {
  group('ground state', () {
    test('printable characters are printed', () {
      expect(parse('abc'), ['print:a', 'print:b', 'print:c']);
    });

    test('the C0 controls a terminal acts on are executed', () {
      expect(parse('\x08\x09\x0A\x0B\x0C\x0D'), [
        'exec:0x08',
        'exec:0x09',
        'exec:0x0a',
        'exec:0x0b',
        'exec:0x0c',
        'exec:0x0d',
      ]);
    });

    test('BEL and DEL are ignored', () {
      expect(parse('\x07\x7F'), isEmpty);
    });

    test('other C0 controls are ignored, never printed as glyphs', () {
      // Rendering these as text is the classic way a terminal shows garbage on binary output.
      expect(parse('\x00\x01\x02\x1C\x1F'), isEmpty);
    });

    test('astral code points print in the ground state', () {
      final events = parse('🚀');
      expect(events, hasLength(1));
      expect(events.single, startsWith('print:'));
    });
  });

  group('CSI', () {
    test('a bare sequence dispatches with empty params', () {
      expect(parse('\x1B[H'), ['csi:H']);
    });

    test('parameters are carried through', () {
      expect(parse('\x1B[12;40H'), ['csi:12;40H']);
    });

    test('a private marker is separated from the body', () {
      expect(parse('\x1B[?1049h'), ['csi:?1049h']);
    });

    test('SGR sequences dispatch', () {
      expect(parse('\x1B[1;31m'), ['csi:1;31m']);
      expect(parse('\x1B[38;2;255;0;0m'), ['csi:38;2;255;0;0m']);
    });

    test('intermediates are accepted', () {
      expect(parse('\x1B[ q'), ['csi: q']);
      expect(parse('\x1B[!p'), ['csi:!p']);
    });

    test('an aborted sequence resets to ground and the next text prints', () {
      // A byte outside both the parameter and final ranges cancels the sequence.
      expect(parse('\x1B[12\x01Xok'), ['print:X', 'print:o', 'print:k']);
    });

    test('an over-long sequence is abandoned rather than buffered', () {
      // A remote that never sends a final byte must not be able to grow memory without bound. On
      // overflow the parser drops the buffer and returns to ground, so the *remaining* parameter
      // bytes are then ordinary text — matching the Kotlin exactly. The property that matters is
      // that nothing is buffered indefinitely and no giant CSI is ever dispatched.
      final sink = RecordingSink();
      final parser = TerminalParser(sink);
      for (final c in '\x1B['.runes) {
        parser.processCodePoint(c);
      }
      const overflowBy = 50;
      for (var i = 0; i < TerminalParser.maxControlSequenceChars + overflowBy; i++) {
        parser.processCodePoint(0x31); // '1'
      }
      parser.processCodePoint(0x48); // 'H'

      expect(
        sink.events.where((e) => e.startsWith('csi:')),
        isEmpty,
        reason: 'the abandoned sequence must never dispatch',
      );
      // The overflowing byte itself is consumed; the rest spill as text, ending with the 'H'.
      expect(sink.events, hasLength(overflowBy));
      expect(sink.events.last, 'print:H');
      expect(sink.events.first, 'print:1');
    });

    test('text after a completed sequence prints normally', () {
      expect(parse('\x1B[2Jhi'), ['csi:2J', 'print:h', 'print:i']);
    });
  });

  group('ESC', () {
    test('the two-character sequences dispatch', () {
      expect(parse('\x1BM'), ['esc:M']);
      expect(parse('\x1BD'), ['esc:D']);
      expect(parse('\x1BE'), ['esc:E']);
      expect(parse('\x1B7'), ['esc:7']);
      expect(parse('\x1B8'), ['esc:8']);
    });

    test('ESC c is a full reset', () {
      expect(parse('\x1Bc'), ['reset']);
    });

    test('keypad mode sequences are ignored', () {
      expect(parse('\x1B=\x1B>'), isEmpty);
    });

    test('a charset designator consumes exactly one following byte', () {
      // ESC ( B selects ASCII; the B must not print.
      expect(parse('\x1B(Bok'), ['print:o', 'print:k']);
      expect(parse('\x1B)0x'), ['print:x']);
    });

    test('an unknown ESC sequence is ignored and parsing resumes', () {
      expect(parse('\x1BZok'), ['print:o', 'print:k']);
    });
  });

  group('OSC', () {
    test('a BEL-terminated string is swallowed', () {
      expect(parse('\x1B]0;my title\x07done'), [
        'print:d',
        'print:o',
        'print:n',
        'print:e',
      ]);
    });

    test('an ST-terminated string is swallowed', () {
      expect(parse('\x1B]0;my title\x1B\\done'), [
        'print:d',
        'print:o',
        'print:n',
        'print:e',
      ]);
    });

    test('an ESC inside the payload does not end it prematurely', () {
      expect(parse('\x1B]8;;http://x\x1Bnot-st\x07after'), [
        'print:a',
        'print:f',
        'print:t',
        'print:e',
        'print:r',
      ]);
    });

    test('OSC 52 is parsed and ignored, never acted on', () {
      // The compatibility matrix is explicit that clipboard writes are not honoured.
      expect(parse('\x1B]52;c;aGVsbG8=\x07'), isEmpty);
    });
  });

  group('DCS / APC / PM', () {
    test('a DCS payload is discarded', () {
      expect(parse('\x1BPsome-dcs-payload\x1B\\ok'), ['print:o', 'print:k']);
    });

    test('an APC payload is discarded', () {
      expect(parse('\x1B_apc data\x07ok'), ['print:o', 'print:k']);
    });

    test('a PM payload is discarded', () {
      expect(parse('\x1B^pm data\x07ok'), ['print:o', 'print:k']);
    });
  });

  group('parser state', () {
    test('reset returns a mid-sequence parser to ground', () {
      final sink = RecordingSink();
      final parser = TerminalParser(sink);
      parser
        ..processCodePoint(0x1B)
        ..processCodePoint(0x5B); // ESC [
      expect(parser.isGround, isFalse);
      parser.reset();
      expect(parser.isGround, isTrue);
      parser.processCodePoint(0x41); // 'A'
      expect(sink.events, ['print:A']);
    });

    test('a sequence split across feeds still parses', () {
      // Read boundaries fall wherever the network puts them.
      final sink = RecordingSink();
      final parser = TerminalParser(sink);
      for (final c in '\x1B[1'.runes) {
        parser.processCodePoint(c);
      }
      expect(sink.events, isEmpty);
      for (final c in ';31m'.runes) {
        parser.processCodePoint(c);
      }
      expect(sink.events, ['csi:1;31m']);
    });
  });

  group('CSI parameter helpers', () {
    test('an omitted parameter is null, not zero', () {
      // CSI ;5H must leave the row defaulted while setting the column.
      expect(parseCsiParams(';5'), [null, 5]);
      expect(parseCsiParams(''), [null]);
      expect(parseCsiParams('1;2;3'), [1, 2, 3]);
    });

    test('csiParam applies the caller default', () {
      final params = parseCsiParams(';5');
      expect(csiParam(params, 0), 0);
      expect(csiParam(params, 0, fallback: 24), 24);
      expect(csiParam(params, 1), 5);
      expect(csiParam(params, 9, fallback: 7), 7, reason: 'out of range');
    });

    test('csiParamOrOne treats 0 and absent alike', () {
      // CSI A and CSI 0A both move exactly one row.
      expect(csiParamOrOne(parseCsiParams(''), 0), 1);
      expect(csiParamOrOne(parseCsiParams('0'), 0), 1);
      expect(csiParamOrOne(parseCsiParams('5'), 0), 5);
      expect(csiParamOrOne(parseCsiParams('1;2'), 1), 2);
    });

    test('unparseable parameters degrade to the default', () {
      expect(parseCsiParams('x;3'), [null, 3]);
    });
  });

  group('TerminalCell', () {
    test('blank resets content but can keep a background', () {
      final cell = TerminalCell(text: 'X', fg: 1, bg: 2, bold: true)..blank(bg: 99);
      expect(cell.text, ' ');
      expect(cell.bg, 99);
      expect(cell.bold, isFalse);
    });

    test('copy can override text and width for a moved glyph', () {
      final wide = TerminalCell(text: '日', width: 2, fg: 7, bold: true);
      final continuation = wide.copy(text: '', width: 0);
      expect(continuation.width, 0);
      expect(continuation.text, isEmpty);
      expect(continuation.fg, 7, reason: 'styling travels with the glyph');
      expect(continuation.bold, isTrue);
    });

    test('isBlank ignores foreground but respects background and inverse', () {
      expect(TerminalCell().isBlank, isTrue);
      expect(TerminalCell(fg: 0xFF00FF00).isBlank, isTrue, reason: 'no visible ink on a space');
      expect(TerminalCell(bg: 0xFF00FF00).isBlank, isFalse);
      expect(TerminalCell(inverse: true).isBlank, isFalse);
      expect(TerminalCell(text: 'x').isBlank, isFalse);
    });

    test('sameStyleAs compares attributes, not text', () {
      final a = TerminalCell(text: 'a', bold: true);
      final b = TerminalCell(text: 'b', bold: true);
      final c = TerminalCell(text: 'a');
      expect(a.sameStyleAs(b), isTrue);
      expect(a.sameStyleAs(c), isFalse);
    });

    test('blankRow builds independent cells', () {
      final row = blankRow(3);
      expect(row, hasLength(3));
      row[0].text = 'X';
      expect(row[1].text, ' ', reason: 'cells must not alias one another');
    });

    test('blankRow can carry the pen background', () {
      expect(blankRow(2, bg: 0xFF123456).every((c) => c.bg == 0xFF123456), isTrue);
    });

    test('default colours match the ported palette', () {
      final cell = TerminalCell();
      expect(cell.fg, kDefaultFg);
      expect(cell.bg, kDefaultBg);
    });
  });
}
