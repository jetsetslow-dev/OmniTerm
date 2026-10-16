/// Render-ready types handed from the emulator to the UI, ported from the data classes at the foot
/// of `data/term/TerminalEmulator.kt`.
///
/// Deliberately free of any Flutter type: colours are packed ARGB ints, exactly as the Kotlin kept
/// them free of Compose. That is what lets the emulator stay in `lib/data/` with the dependency
/// arrow pointing away from the UI (§16).
library;

/// Default foreground/background, packed ARGB.
const int kDefaultFg = 0xFFC8D4E8;
const int kDefaultBg = 0xFF000000;

/// A run of cells sharing the same attributes.
class TermSpan {
  const TermSpan(
    this.text,
    this.fg,
    this.bg, {
    this.bold = false,
    this.inverse = false,
    this.italic = false,
    this.underline = false,
    this.dim = false,
    this.glyphs = const [],
    this.glyphWidths = const [],
  });

  final String text;
  final int fg;
  final int bg;
  final bool bold;
  final bool inverse;
  final bool italic;
  final bool underline;
  final bool dim;

  /// Grapheme-like terminal glyphs and their display-cell widths; empty for legacy callers.
  ///
  /// The renderer needs these because a cluster's cell count is not derivable from its string
  /// length — an emoji ZWJ sequence is many code points in two columns.
  final List<String> glyphs;
  final List<int> glyphWidths;

  @override
  bool operator ==(Object other) =>
      other is TermSpan &&
      other.text == text &&
      other.fg == fg &&
      other.bg == bg &&
      other.bold == bold &&
      other.inverse == inverse &&
      other.italic == italic &&
      other.underline == underline &&
      other.dim == dim;

  @override
  int get hashCode => Object.hash(text, fg, bg, bold, inverse, italic, underline, dim);

  @override
  String toString() => 'TermSpan(${text.length} chars)';
}

/// One visual row.
///
/// [softWrap] marks a row whose text ran off the right edge and continues on the next row — no
/// newline was ever printed. Consumers turning rows back into text must join a soft-wrapped row
/// with its successor instead of inserting a line break, or copied output gains breaks the remote
/// never sent.
class TermRow {
  const TermRow(this.spans, {this.softWrap = false});

  final List<TermSpan> spans;
  final bool softWrap;

  /// The row's plain text, with no attribute information.
  String get text => spans.map((s) => s.text).join();

  @override
  String toString() => 'TermRow(${spans.length} spans, softWrap: $softWrap)';
}

/// Immutable render snapshot handed to the UI layer.
class TerminalSnapshot {
  const TerminalSnapshot({
    required this.rows,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
    required this.cols,
    this.firstRow = 0,
    int? totalRows,
    this.trimmedRows = 0,
  }) : // Not an initializing formal: the parameter is public (`totalRows`) while the field is
       // private, so the names cannot match.
       // ignore: prefer_initializing_formals
       _totalRows = totalRows;

  final List<TermRow> rows;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
  final int cols;
  final int firstRow;
  final int? _totalRows;

  int get totalRows => _totalRows ?? rows.length;

  /// Cumulative head-trimmed rows; anchors a scrolled-up viewport so it does not jump when
  /// scrollback is trimmed underneath it.
  final int trimmedRows;

  static const empty = TerminalSnapshot(
    rows: [],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: true,
    cols: 80,
    firstRow: 0,
    totalRows: 0,
  );
}
