import 'dart:typed_data';

import 'terminal_cell.dart';
import 'terminal_palette.dart';
import 'terminal_parser.dart';
import 'terminal_snapshot.dart';
import 'terminal_unicode.dart';
import 'utf8_stream_decoder.dart';

/// A compact VT100 / xterm-subset terminal emulator, ported from `data/term/TerminalEmulator.kt`.
///
/// Maintains a character grid + scrollback, a cursor, SGR pen state, scroll regions and an
/// alternate screen. Feed it raw bytes from the PTY via [feed]; read a render-ready [snapshot].
///
/// It knows nothing about Flutter — spans carry packed ARGB ints — so it lives in `lib/data/` with
/// the dependency arrow pointing away from the UI. The escape-sequence state machine is
/// [TerminalParser]; this class implements [TerminalSink] and owns only the screen model.
///
/// The contract is `docs/TERMINAL_COMPATIBILITY.md`: a **defensive** subset. Unknown sequences are
/// ignored rather than rendered as text, and malformed input never throws — a terminal that throws
/// on hostile output is a terminal that can be killed by `cat`ing a binary.
class TerminalEmulator implements TerminalSink {
  TerminalEmulator({int cols = 80, int rows = 24, int scrollbackLimit = 2000})
    : _cols = cols < 1 ? 1 : cols,
      _rows = rows < 1 ? 1 : rows,
      _scrollbackLimit = scrollbackLimit < 0 ? 0 : scrollbackLimit {
    _parser = TerminalParser(this);
    _screen = List.generate(_rows, (_) => blankRow(_cols), growable: false);
    _scrollBottom = _rows - 1;
  }

  int _cols;
  int _rows;
  int _scrollbackLimit;

  int get cols => _cols;
  int get rows => _rows;

  late final TerminalParser _parser;
  final Utf8StreamDecoder _decoder = Utf8StreamDecoder();

  late List<List<TerminalCell>> _screen;
  final List<List<TerminalCell>> _scrollback = [];

  /// Cached spans for scrollback rows, which never change once trimmed off the live screen.
  ///
  /// Keyed by row identity. Dart's `List` does not override `==`, so a plain [Map] *is* an identity
  /// map here — the Kotlin needed an explicit `IdentityHashMap` only because arrays there behave the
  /// same way but the intent had to be stated.
  final Map<List<TerminalCell>, TermRow> _scrollbackSpanCache = {};

  /// Rows that ended by a soft wrap (text ran off the right edge) rather than an explicit newline.
  ///
  /// The value is the number of real occupied columns before the wrap: a wide glyph can pre-wrap
  /// with one structural blank left at the edge, and retaining this length stops resize/copy from
  /// turning that padding into a real space. Keyed by row identity so it follows a row through
  /// [_scrollUp].
  final Map<List<TerminalCell>, int> _softWrapped = {};

  // Alternate screen save slot.
  List<List<TerminalCell>>? _savedScreen;
  int _altSavedCursorRow = 0;
  int _altSavedCursorCol = 0;
  bool _altSavedWrapPending = false;
  bool _altActive = false;
  bool _captureAlternateScreenScrollback = false;

  // Cursor + pen.
  int _curRow = 0;
  int _curCol = 0;
  bool _wrapPending = false;
  int _penFg = kDefaultFg;
  int _penBg = kDefaultBg;
  bool _penBold = false;
  bool _penInverse = false;
  bool _penItalic = false;
  bool _penUnderline = false;
  bool _penDim = false;
  bool _cursorVisible = true;

  bool _applicationCursorKeys = false;
  bool _bracketedPasteMode = false;

  /// DECCKM — cursor keys send SS3 rather than CSI while set.
  bool get applicationCursorKeys => _applicationCursorKeys;

  /// DECSET 2004 — pasted blocks are wrapped in the begin/end markers.
  bool get bracketedPasteMode => _bracketedPasteMode;

  bool get isAlternateScreenActive => _altActive;

  // Saved cursor (DECSC / DECRC).
  int _savedRow = 0;
  int _savedCol = 0;

  // Scroll region, inclusive and 0-based.
  int _scrollTop = 0;
  late int _scrollBottom;

  /// Cumulative rows trimmed off the head of scrollback; anchors a scrolled-up viewport so it does
  /// not jump when history is discarded underneath it.
  int _trimmedRowCount = 0;

  // ── public API ─────────────────────────────────────────────────────────────

  void reset() {
    _screen = List.generate(_rows, (_) => blankRow(_cols), growable: false);
    _scrollback.clear();
    _scrollbackSpanCache.clear();
    _softWrapped.clear();
    _savedScreen = null;
    _altSavedCursorRow = 0;
    _altSavedCursorCol = 0;
    _altSavedWrapPending = false;
    _altActive = false;
    _curRow = 0;
    _curCol = 0;
    _wrapPending = false;
    _resetPen();
    _cursorVisible = true;
    _applicationCursorKeys = false;
    _bracketedPasteMode = false;
    _scrollTop = 0;
    _scrollBottom = _rows - 1;
    _parser.reset();
    _decoder.reset();
  }

  /// tmux-backed persistent sessions need app scrollback even on the alternate screen, because tmux
  /// itself runs as a full-screen client. Ordinary alt-screen apps own their display and must not
  /// pour their repaints into history.
  void setCaptureAlternateScreenScrollback(bool enabled) =>
      _captureAlternateScreenScrollback = enabled;

  /// Feed raw bytes from the remote. Handles UTF-8 split across chunk boundaries.
  void feed(Uint8List bytes) => _processDecoded(_decoder.decode(bytes));

  /// Flush an incomplete trailing UTF-8 sequence when a transport reaches EOF.
  void finishInput() => _processDecoded(_decoder.finish());

  void _processDecoded(String text) {
    for (final codePoint in text.runes) {
      _parser.processCodePoint(codePoint);
    }
  }

  /// Resize the grid.
  ///
  /// **Reflow is not yet implemented** — see MIGRATION.md §18. The Kotlin re-joins soft-wrapped runs
  /// and re-wraps them at the new width so a narrowed window does not truncate history. This port
  /// currently preserves content top-left and clamps the cursor, which is correct but loses the
  /// re-wrap. Tracked as a parity gap rather than left silent.
  void resize(int newCols, int newRows) {
    final nc = newCols < 1 ? 1 : newCols;
    final nr = newRows < 1 ? 1 : newRows;
    if (nc == _cols && nr == _rows) return;

    _screen = _resizeGrid(_screen, nc, nr);
    final saved = _savedScreen;
    if (saved != null) _savedScreen = _resizeGrid(saved, nc, nr);

    _cols = nc;
    _rows = nr;
    _scrollTop = 0;
    _scrollBottom = _rows - 1;
    _curRow = _curRow.clamp(0, _rows - 1);
    _curCol = _curCol.clamp(0, _cols - 1);
    _wrapPending = false;
    // Cached spans were built at the old width.
    _scrollbackSpanCache.clear();
  }

  List<List<TerminalCell>> _resizeGrid(List<List<TerminalCell>> old, int nc, int nr) {
    return List.generate(nr, (r) {
      final row = blankRow(nc);
      if (r < old.length) {
        final source = old[r];
        for (var c = 0; c < nc && c < source.length; c++) {
          _copyCell(source[c], row[c]);
        }
        _normalizeWideCells(row);
      }
      return row;
    }, growable: false);
  }

  int rowCount() => _scrollback.length + _rows;

  int scrollbackRowCount() => _scrollback.length;

  int get trimmedRowCount => _trimmedRowCount;

  void setScrollbackLimit(int limit) {
    _scrollbackLimit = limit < 0 ? 0 : limit;
    _trimScrollbackToLimit();
  }

  void clearScrollback() {
    _scrollback.clear();
    _scrollbackSpanCache.clear();
  }

  /// Full render snapshot: scrollback followed by the live screen.
  TerminalSnapshot snapshot() => snapshotRange(0, rowCount());

  /// A window of [count] rows starting at [firstRow], so the UI can render a viewport without
  /// building spans for a hundred thousand scrollback rows it will not draw.
  TerminalSnapshot snapshotRange(int firstRow, int count) {
    final total = rowCount();
    final start = firstRow.clamp(0, total);
    final end = (start + (count < 0 ? 0 : count)).clamp(start, total);
    return TerminalSnapshot(
      rows: [for (var i = start; i < end; i++) _rowAt(i)],
      cursorRow: _scrollback.length + _curRow - start,
      cursorCol: _curCol,
      cursorVisible: _cursorVisible,
      cols: _cols,
      firstRow: start,
      totalRows: total,
      trimmedRows: _trimmedRowCount,
    );
  }

  /// Take over another emulator's history — used when a reconnect replaces the live session but the
  /// user's scrollback must survive.
  void adoptScrollbackFrom(TerminalEmulator source) {
    if (identical(source, this)) return;
    _scrollback
      ..clear()
      ..addAll(source._scrollback);
    _scrollbackSpanCache.clear();
    _trimmedRowCount = source._trimmedRowCount;
    _trimScrollbackToLimit(countTrims: false);
  }

  void _trimScrollbackToLimit({bool countTrims = true}) {
    while (_scrollback.length > _scrollbackLimit) {
      final removed = _scrollback.removeAt(0);
      _scrollbackSpanCache.remove(removed);
      _softWrapped.remove(removed);
      if (countTrims) _trimmedRowCount++;
    }
  }

  // ── TerminalSink ───────────────────────────────────────────────────────────

  @override
  void print(int codePoint) => _putCodePoint(codePoint);

  @override
  void execute(int control) {
    switch (control) {
      case 0x08:
        _backspace();
      case 0x09:
        _tab();
      case 0x0A:
      case 0x0B:
      case 0x0C:
        _lineFeed();
      case 0x0D:
        _curCol = 0;
        _wrapPending = false;
    }
  }

  @override
  void escDispatch(String finalByte) {
    switch (finalByte) {
      case 'M':
        _reverseIndex();
      case 'D':
        _lineFeed();
      case 'E':
        _curCol = 0;
        _lineFeed();
      case '7':
        _savedRow = _curRow;
        _savedCol = _curCol;
      case '8':
        _curRow = _savedRow.clamp(0, _rows - 1);
        _curCol = _savedCol.clamp(0, _cols - 1);
        _wrapPending = false;
    }
  }

  @override
  void fullReset() => reset();

  @override
  void csiDispatch(String params, {required bool private, required String finalByte}) {
    final parsed = parseCsiParams(params);
    int p(int i, {int fallback = 0}) => csiParam(parsed, i, fallback: fallback);
    int p1(int i) => csiParamOrOne(parsed, i);

    switch (finalByte) {
      case 'A':
        _moveCursor(_curRow - p1(0), _curCol);
      case 'B':
        _moveCursor(_curRow + p1(0), _curCol);
      case 'C':
        _moveCursor(_curRow, _curCol + p1(0));
      case 'D':
        _moveCursor(_curRow, _curCol - p1(0));
      case 'E':
        _moveCursor(_curRow + p1(0), 0);
      case 'F':
        _moveCursor(_curRow - p1(0), 0);
      case 'G':
      case '`':
        _moveCursor(_curRow, p1(0) - 1);
      case 'd':
        _moveCursor(p1(0) - 1, _curCol);
      case 'H':
      case 'f':
        _moveCursor(p1(0) - 1, p1(1) - 1);
      case 'J':
        _eraseInDisplay(p(0));
      case 'K':
        _eraseInLine(p(0));
      case 'L':
        _insertLines(p1(0));
      case 'M':
        _deleteLines(p1(0));
      case 'P':
        _deleteChars(p1(0));
      case '@':
        _insertChars(p1(0));
      case 'X':
        _eraseChars(p1(0));
      case 'S':
        _scrollUp(p1(0));
      case 'T':
        _scrollDown(p1(0));
      case 'm':
        _applySgr(parsed);
      case 'r':
        _scrollTop = (p1(0) - 1).clamp(0, _rows - 1);
        _scrollBottom = (p(1, fallback: _rows) - 1).clamp(_scrollTop, _rows - 1);
        _curRow = 0;
        _curCol = 0;
        _wrapPending = false;
      case 'h':
        _setMode(private, parsed, true);
      case 'l':
        _setMode(private, parsed, false);
      // ANSI SCOSC/SCORC are the *bare* CSI s/u forms. Modern clients (Claude, Codex) also use
      // Kitty's keyboard protocol, whose push/pop/query controls end in `u` but carry `<`, `>`, `?`
      // or `=` parameters. Treating those as SCORC jumps the cursor to our old save slot just before
      // 1049 saves the primary-screen cursor; when the TUI exits the shell then resumes at the top
      // and paints over stale rows.
      case 's':
        if (params.isEmpty && !private) {
          _savedRow = _curRow;
          _savedCol = _curCol;
        }
      case 'u':
        if (params.isEmpty && !private) {
          _curRow = _savedRow.clamp(0, _rows - 1);
          _curCol = _savedCol.clamp(0, _cols - 1);
        }
      // Anything else is unsupported and deliberately ignored.
    }
  }

  // ── modes ──────────────────────────────────────────────────────────────────

  void _setMode(bool private, List<int?> params, bool enable) {
    if (!private) return;
    for (final code in params) {
      switch (code) {
        case 25:
          _cursorVisible = enable;
        case 1:
          _applicationCursorKeys = enable;
        case 2004:
          _bracketedPasteMode = enable;
        // 47/1047 switch buffers only — they must NOT restore the cursor (that is 1048's job, and
        // 1049's as a combined op). xterm also requires clearing the alternate buffer before 1047
        // switches back, so its content cannot leak into a later entry.
        case 47:
        case 1047:
          if (!enable && _altActive) {
            _screen = List.generate(_rows, (_) => blankRow(_cols), growable: false);
          }
          _switchAltScreen(enable, restoreCursor: false);
        // 1048 = save/restore cursor only, no buffer switch. Without it a TUI using the 1048/47 pair
        // rather than 1049 leaves the cursor wherever the TUI left it, so the shell's next prompt
        // paints over the restored screen from the top.
        case 1048:
          if (enable) {
            _altSavedCursorRow = _curRow;
            _altSavedCursorCol = _curCol;
            _altSavedWrapPending = _wrapPending;
          } else {
            _curRow = _altSavedCursorRow.clamp(0, _rows - 1);
            _curCol = _altSavedCursorCol.clamp(0, _cols - 1);
            _wrapPending = _altSavedWrapPending && _curCol == _cols - 1;
          }
        // 1049 = save cursor + switch + clear on entry; restore both on exit.
        case 1049:
          _switchAltScreen(enable, restoreCursor: true);
      }
    }
  }

  /// Enter or leave the alternate screen.
  ///
  /// [restoreCursor] distinguishes 1049 (save on entry, restore on exit) from the bare 47/1047
  /// buffer switch, which must leave the cursor untouched — restoring it there would move the cursor
  /// somewhere the application never asked for.
  void _switchAltScreen(bool toAlt, {required bool restoreCursor}) {
    if (toAlt == _altActive) return;
    if (toAlt) {
      _savedScreen = _screen;
      if (restoreCursor) {
        _altSavedCursorRow = _curRow;
        _altSavedCursorCol = _curCol;
        _altSavedWrapPending = _wrapPending;
      }
      _screen = List.generate(_rows, (_) => blankRow(_cols), growable: false);
      _altActive = true;
      _curRow = 0;
      _curCol = 0;
      _wrapPending = false;
    } else {
      // Falling back to a blank grid would wipe the shell's scrollback-visible screen; that only
      // happens if the app leaves the alt screen without ever having entered it.
      _screen = _savedScreen ?? List.generate(_rows, (_) => blankRow(_cols), growable: false);
      _savedScreen = null;
      _altActive = false;
      if (restoreCursor) {
        _curRow = _altSavedCursorRow.clamp(0, _rows - 1);
        _curCol = _altSavedCursorCol.clamp(0, _cols - 1);
        _wrapPending = _altSavedWrapPending && _curCol == _cols - 1;
      } else {
        _curRow = _curRow.clamp(0, _rows - 1);
        _curCol = _curCol.clamp(0, _cols - 1);
      }
    }
  }

  // ── printing ───────────────────────────────────────────────────────────────

  void _putCodePoint(int codePoint) {
    final displayWidth = codePointWidth(codePoint);
    if (displayWidth == 0) {
      _appendCombiningCodePoint(codePoint);
      return;
    }
    if (_appendJoinedCodePoint(codePoint)) return;

    if (_wrapPending) {
      // The previous glyph filled the last column and more text follows: this row continues onto
      // the next (a soft wrap). Recorded so a later reflow re-joins the logical line.
      if (_curRow >= 0 && _curRow < _rows) _softWrapped[_screen[_curRow]] = _cols;
      _curCol = 0;
      _lineFeed();
      _wrapPending = false;
    }

    var width = displayWidth;
    if (width == 2 && _cols == 1) width = 1;
    if (width == 2 && _curCol == _cols - 1) {
      // A wide glyph cannot be split; wrap before it when only one column remains.
      if (_curRow >= 0 && _curRow < _rows) _softWrapped[_screen[_curRow]] = _curCol;
      _curCol = 0;
      _lineFeed();
    }
    if (_curRow < 0 || _curRow >= _rows || _curCol < 0 || _curCol >= _cols) return;

    _clearWideGlyphAt(_screen[_curRow], _curCol);
    _screen[_curRow][_curCol].set(
      String.fromCharCode(codePoint),
      _penFg,
      _penBg,
      bold: _penBold,
      inverse: _penInverse,
      italic: _penItalic,
      underline: _penUnderline,
      dim: _penDim,
      width: width,
    );
    if (width == 2) {
      _clearWideGlyphAt(_screen[_curRow], _curCol + 1);
      _screen[_curRow][_curCol + 1].set(
        '',
        _penFg,
        _penBg,
        bold: _penBold,
        inverse: _penInverse,
        italic: _penItalic,
        underline: _penUnderline,
        dim: _penDim,
        width: 0,
      );
    }

    final lastOccupied = _curCol + width - 1;
    if (lastOccupied == _cols - 1) {
      _curCol = _cols - 1;
      _wrapPending = true;
    } else {
      _curCol += width;
    }
  }

  void _appendCombiningCodePoint(int codePoint) {
    if (_curRow < 0 || _curRow >= _screen.length) return;
    int column;
    if (_wrapPending) {
      column = _cols - 1;
    } else if (_curCol > 0) {
      column = _curCol - 1;
    } else {
      // Preserve a leading mark visibly instead of silently discarding remote output.
      _putCodePoint(0x25CC); // dotted circle
      column = _wrapPending ? _cols - 1 : (_curCol - 1).clamp(0, _cols - 1);
    }
    if (_screen[_curRow][column].width == 0 && column > 0) column--;
    final cell = _screen[_curRow][column];
    if (cell.width <= 0) return;
    cell.text += String.fromCharCode(codePoint);
    _repairClusterWidth(column);
  }

  bool _appendJoinedCodePoint(int codePoint) {
    if (_curRow < 0 || _curRow >= _screen.length) return false;
    int column;
    if (_wrapPending) {
      column = _cols - 1;
    } else if (_curCol > 0) {
      column = _curCol - 1;
    } else {
      return false;
    }
    if (_screen[_curRow][column].width == 0 && column > 0) column--;
    final cell = _screen[_curRow][column];
    if (cell.width <= 0 || cell.text.isEmpty) return false;

    final runes = cell.text.runes.toList();
    final last = runes.last;
    final first = runes.first;
    final joinsZwjSequence = last == 0x200D;
    final joinsRegionalFlag =
        first >= 0x1F1E6 &&
        first <= 0x1F1FF &&
        codePoint >= 0x1F1E6 &&
        codePoint <= 0x1F1FF &&
        runes.length == 1;
    if (!joinsZwjSequence && !joinsRegionalFlag) return false;

    cell.text += String.fromCharCode(codePoint);
    _repairClusterWidth(column);
    return true;
  }

  /// Reconcile the occupied cells after a variation selector/joiner extended a grapheme.
  void _repairClusterWidth(int column) {
    if (_curRow < 0 || _curRow >= _screen.length) return;
    if (column < 0 || column >= _cols) return;
    final row = _screen[_curRow];
    final cell = row[column];
    final target = clusterDisplayWidth(cell.text).clamp(0, _cols);
    if (target == cell.width || cell.width <= 0) return;

    if (target == 2 && cell.width == 1) {
      if (column == _cols - 1) {
        if (_cols == 1) return;
        final moved = cell.copy(width: 2);
        cell.blank(bg: cell.bg);
        _softWrapped[row] = column;
        _wrapPending = false;
        _curCol = 0;
        _lineFeed();
        final destination = _screen[_curRow];
        destination[0] = moved;
        destination[1] = moved.copy(text: '', width: 0);
        _curCol = 2;
        if (_curCol >= _cols) {
          _curCol = _cols - 1;
          _wrapPending = true;
        }
      } else {
        cell.width = 2;
        _clearWideGlyphAt(row, column + 1);
        row[column + 1] = cell.copy(text: '', width: 0);
        if (_curCol > column) _curCol++;
        if (column + 1 == _cols - 1) {
          _curCol = _cols - 1;
          _wrapPending = true;
        }
      }
    } else if (target == 1 && cell.width == 2) {
      cell.width = 1;
      if (column + 1 < _cols && row[column + 1].width == 0) {
        row[column + 1].blank(bg: cell.bg);
      }
      if (_curCol > column + 1) _curCol--;
      _wrapPending = false;
    }
  }

  /// Blank whichever half of a wide pair overlaps [column], so a partial overwrite cannot leave an
  /// orphaned lead or continuation behind.
  void _clearWideGlyphAt(List<TerminalCell> row, int column) {
    if (column < 0 || column >= row.length) return;
    switch (row[column].width) {
      case 0:
        row[column].blank(bg: _penBg);
        if (column > 0 && row[column - 1].width == 2) row[column - 1].blank(bg: _penBg);
      case 2:
        row[column].blank(bg: _penBg);
        if (column + 1 < row.length && row[column + 1].width == 0) {
          row[column + 1].blank(bg: _penBg);
        }
    }
  }

  /// Repair lead/continuation pairs after a shift moved cells around.
  void _normalizeWideCells(List<TerminalCell> row) {
    for (var column = 0; column < row.length; column++) {
      final cell = row[column];
      if (cell.width == 0) {
        if (column == 0 || row[column - 1].width != 2) cell.blank(bg: cell.bg);
      } else if (cell.width == 2) {
        if (column == row.length - 1) {
          cell.blank(bg: cell.bg);
        } else if (row[column + 1].width != 0) {
          row[column + 1].set(
            '',
            cell.fg,
            cell.bg,
            bold: cell.bold,
            inverse: cell.inverse,
            italic: cell.italic,
            underline: cell.underline,
            dim: cell.dim,
            width: 0,
          );
        }
      }
    }
  }

  // ── cursor and scrolling ───────────────────────────────────────────────────

  void _backspace() {
    if (_wrapPending) {
      _wrapPending = false;
      return;
    }
    if (_curCol > 0) {
      _curCol--;
      if (_screen[_curRow][_curCol].width == 0 && _curCol > 0) _curCol--;
    }
  }

  void _tab() {
    _wrapPending = false;
    final next = ((_curCol ~/ 8) + 1) * 8;
    _curCol = next < _cols - 1 ? next : _cols - 1;
  }

  void _lineFeed() {
    _wrapPending = false;
    if (_curRow == _scrollBottom) {
      _scrollUp(1);
    } else if (_curRow < _rows - 1) {
      _curRow++;
    }
  }

  void _reverseIndex() {
    _wrapPending = false;
    if (_curRow == _scrollTop) {
      _scrollDown(1);
    } else if (_curRow > 0) {
      _curRow--;
    }
  }

  void _moveCursor(int row, int col) {
    _curRow = row.clamp(0, _rows - 1);
    _curCol = col.clamp(0, _cols - 1);
    _wrapPending = false;
  }

  void _scrollUp(int n) {
    final count = n.clamp(1, _scrollBottom - _scrollTop + 1);
    for (var i = 0; i < count; i++) {
      final top = _screen[_scrollTop];
      // Capture scrollback only when scrolling the whole screen. Ordinary alternate-screen apps own
      // their display, but tmux-backed sessions need app scrollback because tmux itself runs as a
      // full-screen client.
      if ((!_altActive || _captureAlternateScreenScrollback) && _scrollTop == 0) {
        _scrollback.add(top);
        _trimScrollbackToLimit();
      }
      for (var r = _scrollTop; r < _scrollBottom; r++) {
        _screen[r] = _screen[r + 1];
      }
      _screen[_scrollBottom] = blankRow(_cols, bg: _penBg);
    }
  }

  void _scrollDown(int n) {
    final count = n.clamp(1, _scrollBottom - _scrollTop + 1);
    for (var i = 0; i < count; i++) {
      for (var r = _scrollBottom; r > _scrollTop; r--) {
        _screen[r] = _screen[r - 1];
      }
      _screen[_scrollTop] = blankRow(_cols, bg: _penBg);
    }
  }

  void _insertLines(int n) {
    if (_curRow < _scrollTop || _curRow > _scrollBottom) return;
    final count = n.clamp(1, _scrollBottom - _curRow + 1);
    for (var i = 0; i < count; i++) {
      for (var r = _scrollBottom; r > _curRow; r--) {
        _screen[r] = _screen[r - 1];
      }
      _screen[_curRow] = blankRow(_cols, bg: _penBg);
    }
  }

  void _deleteLines(int n) {
    if (_curRow < _scrollTop || _curRow > _scrollBottom) return;
    final count = n.clamp(1, _scrollBottom - _curRow + 1);
    for (var i = 0; i < count; i++) {
      for (var r = _curRow; r < _scrollBottom; r++) {
        _screen[r] = _screen[r + 1];
      }
      _screen[_scrollBottom] = blankRow(_cols, bg: _penBg);
    }
  }

  void _insertChars(int n) {
    final line = _screen[_curRow];
    final count = n.clamp(1, _cols - _curCol);
    _clearWideGlyphAt(line, _curCol);
    if (_curCol + count < _cols) _clearWideGlyphAt(line, _curCol + count);
    for (var col = _cols - 1; col >= _curCol + count; col--) {
      _copyCell(line[col - count], line[col]);
    }
    for (var col = _curCol; col < _curCol + count; col++) {
      line[col].blank(bg: _penBg);
    }
    _normalizeWideCells(line);
    _softWrapped.remove(line);
  }

  void _deleteChars(int n) {
    final line = _screen[_curRow];
    final count = n.clamp(1, _cols - _curCol);
    _clearWideGlyphAt(line, _curCol);
    if (_curCol + count < _cols) _clearWideGlyphAt(line, _curCol + count);
    for (var col = _curCol; col < _cols - count; col++) {
      _copyCell(line[col + count], line[col]);
    }
    for (var col = _cols - count; col < _cols; col++) {
      line[col].blank(bg: _penBg);
    }
    _normalizeWideCells(line);
    _softWrapped.remove(line);
  }

  static void _copyCell(TerminalCell src, TerminalCell dst) => dst.set(
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

  void _eraseChars(int n) {
    final line = _screen[_curRow];
    final end = (_curCol + (n < 1 ? 1 : n)).clamp(0, _cols);
    _eraseCellRange(line, _curCol, end);
    _normalizeWideCells(line);
    _softWrapped.remove(line);
  }

  void _eraseInLine(int mode) {
    final line = _screen[_curRow];
    switch (mode) {
      case 0:
        _eraseCellRange(line, _curCol, _cols);
      case 1:
        _eraseCellRange(line, 0, _curCol.clamp(0, _cols - 1) + 1);
      case 2:
        _eraseCellRange(line, 0, _cols);
    }
    _normalizeWideCells(line);
    // Erasing through the right edge (mode 0/2) means this row no longer runs off it, so any
    // recorded soft wrap is stale — a repainted row must not be re-joined with the next one.
    if (mode == 0 || mode == 2) _softWrapped.remove(line);
  }

  /// Erase [start, endExclusive), widening the range so a wide pair is never half-erased.
  void _eraseCellRange(List<TerminalCell> line, int start, int endExclusive) {
    if (line.isEmpty) return;
    var startColumn = start.clamp(0, line.length);
    var endColumn = endExclusive.clamp(startColumn, line.length);
    if (startColumn < line.length && line[startColumn].width == 0 && startColumn > 0) {
      startColumn--;
    }
    if (endColumn > 0 && line[endColumn - 1].width == 2 && endColumn < line.length) {
      endColumn++;
    }
    for (var column = startColumn; column < endColumn; column++) {
      line[column].blank(bg: _penBg);
    }
  }

  void _eraseInDisplay(int mode) {
    switch (mode) {
      case 0:
        _eraseInLine(0);
        for (var r = _curRow + 1; r < _rows; r++) {
          for (var col = 0; col < _cols; col++) {
            _screen[r][col].blank(bg: _penBg);
          }
          _softWrapped.remove(_screen[r]);
        }
      case 1:
        for (var r = 0; r < _curRow; r++) {
          for (var col = 0; col < _cols; col++) {
            _screen[r][col].blank(bg: _penBg);
          }
          _softWrapped.remove(_screen[r]);
        }
        _eraseInLine(1);
      case 2:
      case 3:
        for (var r = 0; r < _rows; r++) {
          for (var col = 0; col < _cols; col++) {
            _screen[r][col].blank(bg: _penBg);
          }
          _softWrapped.remove(_screen[r]);
        }
        if (mode == 3) clearScrollback();
    }
  }

  // ── SGR ────────────────────────────────────────────────────────────────────

  void _applySgr(List<int?> params) {
    if (params.isEmpty || (params.length == 1 && params[0] == null)) {
      _resetPen();
      return;
    }
    var i = 0;
    while (i < params.length) {
      final code = params[i] ?? 0;
      if (code == 0) {
        _resetPen();
      } else if (code == 1) {
        _penBold = true;
      } else if (code == 2) {
        _penDim = true;
      } else if (code == 3) {
        _penItalic = true;
      } else if (code == 4) {
        _penUnderline = true;
      } else if (code == 7) {
        _penInverse = true;
      } else if (code == 22) {
        _penBold = false;
        _penDim = false;
      } else if (code == 23) {
        _penItalic = false;
      } else if (code == 24) {
        _penUnderline = false;
      } else if (code == 27) {
        _penInverse = false;
      } else if (code >= 30 && code <= 37) {
        _penFg = palette256[code - 30];
      } else if (code == 39) {
        _penFg = kDefaultFg;
      } else if (code >= 40 && code <= 47) {
        _penBg = palette256[code - 40];
      } else if (code == 49) {
        _penBg = kDefaultBg;
      } else if (code >= 90 && code <= 97) {
        _penFg = palette256[8 + (code - 90)];
      } else if (code >= 100 && code <= 107) {
        _penBg = palette256[8 + (code - 100)];
      } else if (code == 38) {
        i = _parseExtendedColor(params, i, (c) => _penFg = c);
      } else if (code == 48) {
        i = _parseExtendedColor(params, i, (c) => _penBg = c);
      }
      i++;
    }
  }

  /// `38;5;N` (palette) and `38;2;R;G;B` (truecolor). Returns the index of the last consumed
  /// parameter so the caller's loop skips them.
  int _parseExtendedColor(List<int?> params, int start, void Function(int) set) {
    int at(int i) => (i < params.length ? params[i] : null) ?? 0;
    final kind = start + 1 < params.length ? params[start + 1] : null;
    if (kind == 5) {
      set(palette256[at(start + 2).clamp(0, 255)]);
      return start + 2;
    }
    if (kind == 2) {
      final r = at(start + 2).clamp(0, 255);
      final g = at(start + 3).clamp(0, 255);
      final b = at(start + 4).clamp(0, 255);
      set(0xFF000000 | (r << 16) | (g << 8) | b);
      return start + 4;
    }
    return start;
  }

  void _resetPen() {
    _penFg = kDefaultFg;
    _penBg = kDefaultBg;
    _penBold = false;
    _penInverse = false;
    _penItalic = false;
    _penUnderline = false;
    _penDim = false;
  }

  // ── rendering ──────────────────────────────────────────────────────────────

  static const _emptyRow = TermRow([TermSpan('', kDefaultFg, kDefaultBg)]);

  TermRow _rowToSpans(List<TerminalCell> row) {
    var last = row.length - 1;
    // Trim trailing default blanks so spans stay compact — a mostly-empty 200-column row should not
    // ship 200 characters to the renderer.
    while (last >= 0 && row[last].isBlank) {
      last--;
    }
    if (last < 0) return _emptyRow;

    final spans = <TermSpan>[];
    final buffer = StringBuffer();
    var glyphs = <String>[];
    var glyphWidths = <int>[];
    var style = row[0];

    void flush() {
      spans.add(
        TermSpan(
          buffer.toString(),
          style.fg,
          style.bg,
          bold: style.bold,
          inverse: style.inverse,
          italic: style.italic,
          underline: style.underline,
          dim: style.dim,
          glyphs: glyphs,
          glyphWidths: glyphWidths,
        ),
      );
      buffer.clear();
      glyphs = <String>[];
      glyphWidths = <int>[];
    }

    for (var col = 0; col <= last; col++) {
      final cell = row[col];
      if (!cell.sameStyleAs(style)) {
        flush();
        style = cell;
      }
      if (cell.width > 0) {
        buffer.write(cell.text);
        glyphs.add(cell.text);
        glyphWidths.add(cell.width);
      }
    }
    flush();
    return TermRow(spans, softWrap: _softWrapped.containsKey(row));
  }

  TermRow _rowAt(int index) {
    if (index < _scrollback.length) {
      final row = _scrollback[index];
      return _scrollbackSpanCache[row] ??= _rowToSpans(row);
    }
    return _rowToSpans(_screen[index - _scrollback.length]);
  }
}
