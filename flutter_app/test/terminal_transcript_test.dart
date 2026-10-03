import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_snapshot.dart';
import 'package:omniterm/domain/terminal_transcript.dart';

TermSpan span(String text) => TermSpan(text, kDefaultFg, kDefaultBg);

TermRow row(String text, {bool softWrap = false}) => TermRow([span(text)], softWrap: softWrap);

void main() {
  group('transcriptText', () {
    test('hard-ended rows become separate lines', () {
      expect(transcriptText([row('one'), row('two')]), 'one\ntwo');
    });

    test('a soft-wrapped row is joined to its successor, not broken', () {
      // The whole reason this function exists. A command longer than the terminal is stored as
      // several rows with no newline ever printed; joining them with "\n" produces text that does
      // not run when it is pasted back.
      expect(
        transcriptText([
          row('docker run --rm -it --name ', softWrap: true),
          row('omniterm-test alpine:3 sh'),
        ]),
        'docker run --rm -it --name omniterm-test alpine:3 sh',
      );
    });

    test('a run of soft wraps joins into one line', () {
      expect(transcriptText([row('a', softWrap: true), row('b', softWrap: true), row('c')]), 'abc');
    });

    test('a soft-wrapped row at the very end is still a line', () {
      // The cursor sits mid-line while a command is being typed; that text is not lost.
      expect(transcriptText([row('half-typed comman', softWrap: true)]), 'half-typed comman');
    });

    test('the grid padding is not copied', () {
      // Rows are padded to the terminal width. Keeping that would put hundreds of invisible spaces
      // into the clipboard for every line.
      expect(transcriptText([row('ls -la          ')]), 'ls -la');
    });

    test('trailing blank rows are dropped, interior ones kept', () {
      // A terminal is mostly empty grid below the cursor, and that is not output. A blank line
      // *between* two commands is output — it is what the remote printed.
      expect(transcriptText([row('one'), row(''), row('two'), row(''), row('   ')]), 'one\n\ntwo');
    });

    test('an empty screen copies as nothing rather than a pile of newlines', () {
      expect(transcriptText([row(''), row(''), row('')]), '');
      expect(transcriptText(const []), '');
    });

    test('spans within a row are concatenated', () {
      // Colour changes split a line into spans; they are not line breaks.
      expect(
        transcriptText([
          TermRow([span('error'), span(': '), span('not found')]),
        ]),
        'error: not found',
      );
    });
  });

  group('terminalSemanticsLabel', () {
    // Defect 73. The terminal surface is a CustomPaint, so without a label it contributes nothing
    // to the semantics tree — the app's primary content was unreadable to TalkBack. Kotlin puts a
    // contentDescription on the same surface (`ui/ShellScreen.kt:2047`).

    test('announces the output, prefixed so the node is identifiable', () {
      final label = terminalSemanticsLabel([row('uptime'), row('load average: 0.14')]);
      expect(label, startsWith('Terminal output: '));
      expect(label, contains('uptime'));
      expect(label, contains('load average: 0.14'));
    });

    test('an empty grid is named, not left blank', () {
      // A blank label makes the surface an *unlabelled* node rather than an empty one, which reads
      // as a bug to a screen-reader user rather than as an idle terminal.
      expect(terminalSemanticsLabel([]), 'Terminal output: empty');
    });

    test('long output is capped, keeping the newest', () {
      // The label is re-announced whenever it changes, so an uncapped terminal would read its whole
      // grid on every arriving character. Kotlin caps at the same 2000.
      final rows = [for (var i = 0; i < 500; i++) row('line $i padded out to some width')];
      final label = terminalSemanticsLabel(rows);

      expect(
        label.length,
        lessThanOrEqualTo(terminalSemanticsMaxChars + 'Terminal output: '.length),
      );
      expect(label, contains('line 499'), reason: 'the newest output is what is being read');
      expect(label, isNot(contains('line 0 ')), reason: 'the oldest is what gets dropped');
    });
  });
}
