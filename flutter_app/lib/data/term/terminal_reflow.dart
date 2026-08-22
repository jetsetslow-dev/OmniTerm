/// Re-wrapping the buffer when the window changes width.
///
/// A terminal stores a screen of fixed-width rows, but what the user typed is *logical lines* — a
/// paragraph that happened to run off the right edge and continue on the next row. Narrowing the
/// window without re-wrapping truncates every one of those continuations; widening it leaves the
/// text ragged at the old width. `docs/TERMINAL_COMPATIBILITY.md` lists reflow as supported, and
/// this is what makes that true.
///
/// Pure, and separate from the emulator, because the arithmetic is easy to get subtly wrong (a
/// double-width glyph must never straddle the edge, and the cursor has to end up on the character it
/// was on, not at the coordinates it had).
library;

import 'terminal_cell.dart';

/// What a row's ending means.
///
/// The int is the number of occupied columns before a soft wrap — a wide glyph can pre-wrap leaving
/// one structural blank at the edge, and treating that padding as a real space inserts a space into
/// the user's text every time the window is resized.
typedef WrapLengthOf = int? Function(List<TerminalCell> row);

class ReflowResult {
  const ReflowResult({
    required this.rows,
    required this.softWrapped,
    required this.cursorRow,
    required this.cursorCol,
  });

  /// Every row, oldest first: scrollback then screen, for the caller to split.
  final List<List<TerminalCell>> rows;

  /// The rows that end in a soft wrap, by identity — the same contract the emulator keeps.
  final Set<List<TerminalCell>> softWrapped;

  /// Where the cursor's character ended up.
  final int cursorRow;
  final int cursorCol;
}

/// Re-wraps [rows] to [newCols].
///
/// [cursorRow]/[cursorCol] are indexes into [rows]; the returned pair points at the same character.
/// Rows are rebuilt rather than mutated, so the caller's old rows stay valid until it swaps them in.
ReflowResult reflowRows({
  required List<List<TerminalCell>> rows,
  required WrapLengthOf wrapLengthOf,
  required int newCols,
  required int cursorRow,
  required int cursorCol,
}) {
  final cols = newCols < 1 ? 1 : newCols;

  // ── 1. join: rows that soft-wrapped are continuations of the row above ──────
  final logical = <List<TerminalCell>>[];
  // Where the cursor sits within its logical line, in cells.
  var cursorLogical = -1;
  var cursorOffset = 0;

  List<TerminalCell>? current;
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final wrapAt = wrapLengthOf(row);
    // A hard-ended row keeps its trailing blanks only up to its last real glyph: a shell that
    // padded the row to the edge must not turn into a line of spaces at the new width.
    final take = wrapAt ?? _lastOccupied(row);

    if (current == null) {
      current = [];
      logical.add(current);
    }
    if (r == cursorRow) {
      cursorLogical = logical.length - 1;
      cursorOffset = current.length + cursorCol;
    }
    for (var c = 0; c < take && c < row.length; c++) {
      current.add(row[c].copy());
    }
    // No soft wrap means the logical line ends here.
    if (wrapAt == null) current = null;
  }

  // ── 2. split: re-wrap each logical line at the new width ────────────────────
  final out = <List<TerminalCell>>[];
  final soft = <List<TerminalCell>>{};
  var outCursorRow = 0;
  var outCursorCol = 0;

  for (var i = 0; i < logical.length; i++) {
    final line = logical[i];
    final firstRowOfLine = out.length;
    var index = 0;

    do {
      final row = blankRow(cols);
      var column = 0;
      while (index < line.length && column < cols) {
        final cell = line[index];
        // A double-width glyph that does not fit is pushed whole to the next row, leaving the last
        // column blank — splitting it would render half a character and desynchronise every column
        // after it.
        if (cell.width == 2 && column == cols - 1) break;
        // Continuation cells are rebuilt by the wide glyph that owns them, never carried alone.
        if (cell.width == 0) {
          index++;
          continue;
        }
        _copyInto(cell, row[column]);
        if (cell.width == 2 && column + 1 < cols) {
          row[column + 1]
            ..set('', cell.fg, cell.bg, width: 0)
            ..width = 0;
          column += 2;
        } else {
          column += 1;
        }
        index++;
      }
      out.add(row);
      // Every row of this logical line except the last one ends in a soft wrap.
      if (index < line.length) soft.add(row);
    } while (index < line.length);

    if (i == cursorLogical) {
      // The cursor's offset is counted in source cells, which map one-to-one onto the columns
      // written above except where a wide glyph was pushed down a row. Walking the same wrap points
      // keeps the two in step without a second, divergent calculation.
      final placed = _placeOffset(line, cursorOffset, cols);
      outCursorRow = firstRowOfLine + placed.$1;
      outCursorCol = placed.$2.clamp(0, cols - 1);
    }
  }

  if (out.isEmpty) out.add(blankRow(cols));
  if (cursorLogical < 0) {
    outCursorRow = out.length - 1;
    outCursorCol = cursorCol.clamp(0, cols - 1);
  }

  return ReflowResult(
    rows: out,
    softWrapped: soft,
    cursorRow: outCursorRow.clamp(0, out.length - 1),
    cursorCol: outCursorCol.clamp(0, cols - 1),
  );
}

/// Which (row, column) the cell at [offset] of [line] lands on when wrapped at [cols].
(int, int) _placeOffset(List<TerminalCell> line, int offset, int cols) {
  var row = 0;
  var column = 0;
  for (var i = 0; i < line.length; i++) {
    if (i == offset) return (row, column);
    final cell = line[i];
    if (cell.width == 0) continue;
    if (cell.width == 2 && column == cols - 1) {
      row++;
      column = 0;
    }
    column += cell.width == 2 ? 2 : 1;
    if (column >= cols) {
      row++;
      column = 0;
    }
  }
  // Past the end of the text: the cursor sits just after the last character, which is where a shell
  // leaves it while the user is typing.
  return (row, column);
}

/// One past the last column holding a real glyph, so trailing padding is not preserved as text.
int _lastOccupied(List<TerminalCell> row) {
  for (var c = row.length - 1; c >= 0; c--) {
    final cell = row[c];
    if (cell.width == 0) continue;
    if (cell.text.trim().isNotEmpty) return c + 1;
  }
  return 0;
}

void _copyInto(TerminalCell src, TerminalCell dst) => dst.set(
  src.text,
  src.fg,
  src.bg,
  bold: src.bold,
  inverse: src.inverse,
  italic: src.italic,
  underline: src.underline,
  dim: src.dim,
  width: src.width,
);
