/// Turning terminal rows back into text somebody can copy.
///
/// The terminal surface paints a grid, so there is nothing on screen to select. That is why the
/// Kotlin's answer to "copy this output" is a transcript view rather than a selectable canvas, and
/// this is the rule that view depends on.
///
/// **Soft wrap is the whole problem.** A line longer than the terminal is stored as several rows
/// with no newline ever having been printed. Joining those rows with `\n` — the obvious
/// implementation — inserts breaks the remote never sent, so a copied command does not run when it
/// is pasted back, and a copied path gains a newline in the middle. `TermRow.softWrap` marks
/// exactly those rows; this joins them instead.
library;

import '../data/term/terminal_snapshot.dart';

/// The rows as text, ready to be copied.
///
/// Trailing spaces are dropped per line: the grid is padded to its full width, so keeping them
/// would put hundreds of invisible spaces into the clipboard. Blank lines at the end go too — a
/// terminal is almost always mostly-empty grid below the cursor, and that is not output.
String transcriptText(List<TermRow> rows) {
  final lines = <String>[];
  final current = StringBuffer();

  for (final row in rows) {
    current.write(row.text);
    if (row.softWrap) continue;
    // A hard row end is a real newline the remote sent.
    lines.add(_trimTrailing(current.toString()));
    current.clear();
  }
  // A trailing soft-wrapped row has no terminator; it is still a line.
  if (current.isNotEmpty) lines.add(_trimTrailing(current.toString()));

  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

String _trimTrailing(String line) {
  var end = line.length;
  while (end > 0 && (line.codeUnitAt(end - 1) == 0x20 || line.codeUnitAt(end - 1) == 0x09)) {
    end--;
  }
  return line.substring(0, end);
}

/// The most a screen reader is given in one go.
///
/// Kotlin caps at the same figure (`takeLast(2_000)`, `ui/ShellScreen.kt:2049`). A cap is needed at
/// all because the label is re-announced whenever it changes, and an uncapped terminal would read
/// its entire visible grid every time a character arrived.
const int terminalSemanticsMaxChars = 2000;

/// What a screen reader announces for the painted terminal grid.
///
/// The surface is a `CustomPaint`, so without this there is nothing in the semantics tree at all —
/// the app's primary content is invisible to TalkBack and VoiceOver. Ported from the
/// `contentDescription` Kotlin puts on the same surface (`ui/ShellScreen.kt:2047`), including its
/// prefix and its cap.
///
/// The **tail** is kept rather than the head: a terminal's newest output is the part being read.
String terminalSemanticsLabel(List<TermRow> rows) {
  final text = transcriptText(rows);
  final tail = text.length > terminalSemanticsMaxChars
      ? text.substring(text.length - terminalSemanticsMaxChars)
      : text;
  // An empty grid still needs a name, or the surface is an unlabelled node rather than an empty one.
  return tail.isEmpty ? 'Terminal output: empty' : 'Terminal output: $tail';
}
