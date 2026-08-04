import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/term/terminal_snapshot.dart';
import '../theme/typography.dart';
import '../view_model/shell_session.dart';
import 'terminal_transcript_sheet.dart';

/// The size of one terminal cell for a given font size.
///
/// Measured rather than assumed: the advance of a monospace glyph is a property of the shipped font
/// file, and hard-coding a ratio makes the grid drift from what is actually painted — which shows up
/// as a full-screen app whose right-hand border is one column off.
class TerminalMetrics {
  const TerminalMetrics({
    required this.cellWidth,
    required this.cellHeight,
    required this.fontSize,
  });

  final double cellWidth;
  final double cellHeight;
  final double fontSize;

  /// How many whole cells fit in [size], floored — a partially visible column is not a column the
  /// remote may draw into.
  (int, int) gridFor(Size size) => (
    math.max(1, (size.width / cellWidth).floor()),
    math.max(1, (size.height / cellHeight).floor()),
  );

  static final Map<double, TerminalMetrics> _cache = {};

  /// Measure (once per font size) and cache.
  static TerminalMetrics measure(double fontSize, {double lineHeight = 1.2}) =>
      _cache.putIfAbsent(fontSize, () {
        final painter = TextPainter(
          text: TextSpan(
            // A wide-ish ASCII glyph: in a monospace font every advance is identical, so one is
            // enough, and 'M' is the conventional choice.
            text: 'M',
            style: TextStyle(fontFamily: OmniFonts.mono, fontSize: fontSize, height: lineHeight),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        return TerminalMetrics(
          cellWidth: painter.width,
          cellHeight: painter.height,
          fontSize: fontSize,
        );
      });
}

/// Paints a [TerminalSnapshot] onto a cell grid.
class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.snapshot,
    required this.metrics,
    required this.background,
    required this.showCursor,
  });

  final TerminalSnapshot snapshot;
  final TerminalMetrics metrics;
  final Color background;

  /// The block cursor is drawn only for the focused, live pane — an unfocused split pane showing a
  /// cursor invites typing into the wrong host.
  final bool showCursor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    final cw = metrics.cellWidth;
    final ch = metrics.cellHeight;

    for (var rowIndex = 0; rowIndex < snapshot.rows.length; rowIndex++) {
      final y = rowIndex * ch;
      if (y > size.height) break;
      var col = 0;
      for (final span in snapshot.rows[rowIndex].spans) {
        col = _paintSpan(canvas, span, col, y, cw, ch);
      }
    }

    if (showCursor && snapshot.cursorVisible) {
      final row = snapshot.cursorRow - snapshot.firstRow;
      if (row >= 0 && row < snapshot.rows.length) {
        canvas.drawRect(
          Rect.fromLTWH(snapshot.cursorCol * cw, row * ch, cw, ch),
          Paint()..color = const Color(0xFFC8D4E8).withValues(alpha: 0.65),
        );
      }
    }
  }

  /// Returns the column after [span].
  int _paintSpan(Canvas canvas, TermSpan span, int col, double y, double cw, double ch) {
    if (span.text.isEmpty) return col;

    // Inverse video is applied here rather than by the emulator, because the emulator stores what
    // the remote *said* and the swap is a presentation decision (a themed background has to swap to
    // the theme's colour, not to whatever the remote's default happened to be).
    final fg = Color(span.inverse ? span.bg : span.fg);
    final bg = Color(span.inverse ? span.fg : span.bg);

    final widths = span.glyphWidths;
    final glyphs = span.glyphs;
    // Every glyph one cell wide is the overwhelmingly common case, and it lets the whole run be laid
    // out and painted once. A run containing a wide glyph (CJK, emoji) falls back to placing each
    // glyph at its own column, because a fallback font's advance for those is not reliably 2 cells
    // and letting it flow would shift the rest of the line.
    final uniform = glyphs.isEmpty || widths.length != glyphs.length || widths.every((w) => w == 1);
    final cells = uniform
        ? (glyphs.isEmpty ? span.text.runes.length : glyphs.length)
        : widths.fold<int>(0, (sum, w) => sum + w.clamp(1, 2));

    if (bg.toARGB32() != kDefaultBg) {
      canvas.drawRect(Rect.fromLTWH(col * cw, y, cells * cw, ch), Paint()..color = bg);
    }

    final style = TextStyle(
      fontFamily: OmniFonts.mono,
      fontSize: metrics.fontSize,
      height: metrics.cellHeight / metrics.fontSize,
      color: span.dim ? fg.withValues(alpha: 0.6) : fg,
      fontWeight: span.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: span.italic ? FontStyle.italic : FontStyle.normal,
      decoration: span.underline ? TextDecoration.underline : TextDecoration.none,
      decorationColor: fg,
    );

    if (uniform) {
      _paintText(canvas, span.text, style, col * cw, y);
      return col + cells;
    }

    var cursor = col;
    for (var i = 0; i < glyphs.length; i++) {
      _paintText(canvas, glyphs[i], style, cursor * cw, y);
      cursor += widths[i].clamp(1, 2);
    }
    return cursor;
  }

  void _paintText(Canvas canvas, String text, TextStyle style, double x, double y) {
    if (text.trim().isEmpty) return;
    TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )
      ..layout()
      ..paint(canvas, Offset(x, y));
  }

  @override
  bool shouldRepaint(TerminalPainter old) =>
      !identical(old.snapshot, snapshot) ||
      old.metrics != metrics ||
      old.background != background ||
      old.showCursor != showCursor;
}

/// The scrollable, resizable terminal viewport for one [ShellSession].
///
/// Owns the two things a terminal view must never get wrong: telling the remote the real grid size,
/// and keeping the viewport where the user put it.
class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    super.key,
    required this.session,
    this.fontSize = 13,
    this.background = const Color(0xFF05070C),
    this.focused = true,
    this.onGridChanged,
  });

  final ShellSession session;
  final double fontSize;
  final Color background;
  final bool focused;

  /// Reports the measured grid so the view model can open the *next* session at this size.
  final void Function(int cols, int rows)? onGridChanged;

  @override
  State<TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<TerminalSurface> {
  /// Fractional rows carried between drag events, so a slow drag still scrolls instead of rounding
  /// every delta down to nothing.
  double _dragRemainder = 0;

  @override
  Widget build(BuildContext context) {
    final metrics = TerminalMetrics.measure(widget.fontSize);

    return LayoutBuilder(
      builder: (context, constraints) {
        final (cols, rows) = metrics.gridFor(Size(constraints.maxWidth, constraints.maxHeight));
        // Resizing during layout would mutate state mid-build; the remote is told once the frame
        // this size belongs to has actually been shown.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.onGridChanged?.call(cols, rows);
          widget.session.resize(cols, rows);
        });

        return ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => GestureDetector(
            key: const ValueKey('shell.surface'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _dragRemainder = 0,
            onVerticalDragUpdate: (details) => _onDrag(details.delta.dy, metrics.cellHeight),
            // A painted grid has nothing to select, which left copying output impossible. Long
            // press opens the scrollback as selectable text instead — the Kotlin's answer too.
            onLongPress: () => openTerminalTranscript(context, widget.session),
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: TerminalPainter(
                snapshot: widget.session.snapshot,
                metrics: metrics,
                background: widget.background,
                showCursor: widget.focused && widget.session.followTail,
              ),
            ),
          ),
        );
      },
    );
  }

  void _onDrag(double dy, double cellHeight) {
    // Dragging down reveals earlier output, the same direction as every other scroll view. The
    // Kotlin settled on tracking the local buffer rather than forwarding wheel events to tmux,
    // because the forwarded version had inconsistent direction and never quite reached the bottom.
    _dragRemainder += -dy / cellHeight;
    final whole = _dragRemainder.truncate();
    if (whole == 0) return;
    _dragRemainder -= whole;
    widget.session.scrollBy(whole);
  }
}
