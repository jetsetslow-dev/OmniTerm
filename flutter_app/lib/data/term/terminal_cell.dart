import 'terminal_snapshot.dart';

/// One character cell in the terminal grid, ported from the private `Cell` class in
/// `data/term/TerminalEmulator.kt` (lines 22–46).
///
/// Deliberately **mutable**. The emulator rewrites cells in place tens of thousands of times a
/// second while a build scrolls past; allocating a fresh immutable cell per write would make that
/// path allocation-bound. The immutable view the UI sees is [TermSpan], produced only when a
/// snapshot is taken.
class TerminalCell {
  TerminalCell({
    this.text = ' ',
    this.width = 1,
    this.fg = kDefaultFg,
    this.bg = kDefaultBg,
    this.bold = false,
    this.inverse = false,
    this.italic = false,
    this.underline = false,
    this.dim = false,
  });

  /// The cluster drawn in this cell — usually one character, but a base plus its combining marks,
  /// or a whole ZWJ emoji sequence.
  String text;

  /// Display columns occupied: 2 for a wide lead, 1 normal, **0 for a wide continuation**.
  ///
  /// The zero-width continuation cell is how a double-width glyph reserves its second column, and
  /// most of the grid's fiddly repair logic exists to keep lead/continuation pairs consistent.
  int width;

  int fg;
  int bg;
  bool bold;
  bool inverse;
  bool italic;
  bool underline;
  bool dim;

  void set(
    String value,
    int fg,
    int bg, {
    bool bold = false,
    bool inverse = false,
    bool italic = false,
    bool underline = false,
    bool dim = false,
    int width = 1,
  }) {
    text = value;
    this.width = width;
    this.fg = fg;
    this.bg = bg;
    this.bold = bold;
    this.inverse = inverse;
    this.italic = italic;
    this.underline = underline;
    this.dim = dim;
  }

  /// Reset to a blank cell, optionally keeping a background so an erase paints the current pen.
  void blank({int fg = kDefaultFg, int bg = kDefaultBg}) => set(' ', fg, bg);

  /// A copy, optionally overriding the text/width — used when a glyph has to be moved between
  /// columns (a widening cluster pushed to the next row, for instance).
  TerminalCell copy({String? text, int? width}) => TerminalCell(
    text: text ?? this.text,
    width: width ?? this.width,
    fg: fg,
    bg: bg,
    bold: bold,
    inverse: inverse,
    italic: italic,
    underline: underline,
    dim: dim,
  );

  /// True when this cell carries no visible content and default styling, so trailing runs of them
  /// can be trimmed from a row without changing what the user sees.
  bool get isBlank => text == ' ' && bg == kDefaultBg && !inverse;

  /// Whether two cells would render identically, ignoring their text — the test for whether a span
  /// can be extended rather than started afresh.
  bool sameStyleAs(TerminalCell other) =>
      fg == other.fg &&
      bg == other.bg &&
      bold == other.bold &&
      inverse == other.inverse &&
      italic == other.italic &&
      underline == other.underline &&
      dim == other.dim;
}

/// A fresh row of blank cells.
List<TerminalCell> blankRow(int cols, {int bg = kDefaultBg}) =>
    List.generate(cols, (_) => TerminalCell(bg: bg), growable: false);
