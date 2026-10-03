import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/term/terminal_snapshot.dart';
import '../../domain/tui_scroll_router.dart';
import '../theme/terminal_theme.dart';
import '../theme/text_scaling.dart';
import '../theme/typography.dart';
import '../view_model/shell_session.dart';
import 'terminal_transcript_sheet.dart';
import '../../domain/terminal_transcript.dart';

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
    this.fontFamily = OmniFonts.mono,
    this.lineHeight,
    this.baselineOffset,
  });

  final double cellWidth;
  final double cellHeight;
  final double fontSize;
  final String fontFamily;
  final double? lineHeight;
  final double? baselineOffset;

  /// How many whole cells fit in [size], floored — a partially visible column is not a column the
  /// remote may draw into.
  (int, int) gridFor(Size size) => (
    (size.width / cellWidth).floor().clamp(1, 500),
    (size.height / cellHeight).floor().clamp(1, 300),
  );

  static final Map<(double, String, double?, double, bool), TerminalMetrics> _cache = {};

  /// Measure the same monospace face used to paint the cell, once per scaled size.
  static TerminalMetrics measure(
    double fontSize, {
    String fontFamily = OmniFonts.mono,
    double? lineHeight,
    double devicePixelRatio = 1,
    bool androidMetrics = false,
  }) =>
      _cache.putIfAbsent((fontSize, fontFamily, lineHeight, devicePixelRatio, androidMetrics), () {
        final painter = TextPainter(
          text: TextSpan(
            // Kotlin measures this same glyph with Android Paint before sizing the remote grid.
            text: 'M',
            style: TextStyle(fontFamily: fontFamily, fontSize: fontSize, height: lineHeight),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final line = painter.computeLineMetrics().single;
        // Android Paint hints the advance to a physical pixel, but its font bounds stay fractional.
        // Paragraph height rounds the line box and shifts the baseline; use the actual font bounds
        // to match Kotlin's fm.descent - fm.ascent and its -fm.ascent baseline instead.
        final result = TerminalMetrics(
          cellWidth: androidMetrics
              ? (painter.width * devicePixelRatio).roundToDouble() / devicePixelRatio
              : painter.width,
          cellHeight: androidMetrics ? line.ascent + line.descent : painter.height,
          fontSize: fontSize,
          fontFamily: fontFamily,
          lineHeight: lineHeight,
          baselineOffset: androidMetrics ? line.ascent : null,
        );
        painter.dispose();
        return result;
      });
}

/// Paints a [TerminalSnapshot] onto a cell grid.
class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.snapshot,
    required this.metrics,
    required this.palette,
    required this.showCursor,
  });

  final TerminalSnapshot snapshot;
  final TerminalMetrics metrics;
  final TerminalPalette palette;
  final Map<(String, TextStyle), TextPainter> _textPainters = {};

  /// The block cursor is drawn only for the focused, live pane — an unfocused split pane showing a
  /// cursor invites typing into the wrong host.
  final bool showCursor;

  @override
  void paint(Canvas canvas, Size size) {
    try {
      _paint(canvas, size);
    } finally {
      for (final painter in _textPainters.values) {
        painter.dispose();
      }
      _textPainters.clear();
    }
  }

  void _paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);

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
        final cursorRect = Rect.fromLTWH(snapshot.cursorCol * cw, row * ch, cw, ch);
        canvas.drawRect(cursorRect, Paint()..color = palette.cursor);
        var col = 0;
        for (final span in snapshot.rows[row].spans) {
          for (final (glyph, width) in _glyphs(span)) {
            if (snapshot.cursorCol >= col && snapshot.cursorCol < col + width) {
              // A continuation cell retains its two-cell origin, then clips to the cursor cell.
              canvas.save();
              canvas.clipRect(cursorRect);
              _paintText(
                canvas,
                glyph,
                TextStyle(
                  fontFamily: metrics.fontFamily,
                  fontSize: metrics.fontSize,
                  height: metrics.lineHeight,
                  color: Color(
                    ensureTerminalTextLegible(
                      palette.background.toARGB32(),
                      palette.cursor.toARGB32(),
                    ),
                  ),
                ),
                (col + width / 2) * cw,
                row * ch,
              );
              canvas.restore();
              return;
            }
            col += width;
          }
        }
      }
    }
  }

  Iterable<(String, int)> _glyphs(TermSpan span) sync* {
    final glyphs = span.glyphs.isNotEmpty
        ? span.glyphs
        : span.text.runes.map(String.fromCharCode).toList();
    final hasWidths = span.glyphWidths.length == glyphs.length;
    for (var i = 0; i < glyphs.length; i++) {
      yield (glyphs[i], hasWidths ? span.glyphWidths[i].clamp(1, 2) : 1);
    }
  }

  /// Returns the column after [span].
  int _paintSpan(Canvas canvas, TermSpan span, int col, double y, double cw, double ch) {
    if (span.text.isEmpty) return col;

    // Inverse video is applied here rather than by the emulator, because the emulator stores what
    // the remote *said* and the swap is a presentation decision (a themed background has to swap to
    // the theme's colour, not to whatever the remote's default happened to be).
    final rawFg = span.inverse ? span.bg : span.fg;
    final rawBg = span.inverse ? span.fg : span.bg;
    final effectiveBg = switch (rawBg) {
      kDefaultBg => palette.background.toARGB32(),
      kDefaultFg => palette.foreground.toARGB32(),
      _ => rawBg,
    };
    var resolvedFg = rawFg == kDefaultFg ? palette.foreground.toARGB32() : rawFg;
    final ansi = palette.ansiForeground;
    if (ansi != null && rawFg != kDefaultFg) {
      final index = ansi16Index(rawFg);
      if (index >= 0) resolvedFg = ansi[index];
    }
    if (span.dim) resolvedFg = lerpTerminalArgb(effectiveBg, resolvedFg, 0.6);
    resolvedFg = ensureTerminalTextLegible(resolvedFg, effectiveBg);
    final fg = Color(resolvedFg);
    final bg = Color(effectiveBg);

    final glyphs = _glyphs(span).toList();
    final cells = glyphs.fold<int>(0, (sum, glyph) => sum + glyph.$2);

    if (rawBg != kDefaultBg || span.inverse) {
      canvas.drawRect(Rect.fromLTWH(col * cw, y, cells * cw, ch), Paint()..color = bg);
    }

    final style = TextStyle(
      fontFamily: metrics.fontFamily,
      fontSize: metrics.fontSize,
      height: metrics.lineHeight,
      color: fg,
      fontWeight: span.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: span.italic ? FontStyle.italic : FontStyle.normal,
      decoration: span.underline ? TextDecoration.underline : TextDecoration.none,
      decorationColor: fg,
    );

    var cursor = col;
    for (final (glyph, width) in glyphs) {
      // Pin every glyph to its cell center so intrinsic font advances never accumulate across
      // a run and drift away from the remote's grid, including bold and fallback-font text.
      _paintText(canvas, glyph, style, (cursor + width / 2) * cw, y);
      cursor += width;
    }
    return cursor;
  }

  void _paintText(Canvas canvas, String text, TextStyle style, double centerX, double y) {
    if (text.trim().isEmpty) return;
    // Repeated glyphs of the same style share one layout for this frame; centering every cell
    // should not require thousands of paragraph layouts while a remote TUI redraws.
    final painter = _textPainters.putIfAbsent(
      (text, style),
      () => TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
    final baseline = metrics.baselineOffset;
    final top = baseline == null
        ? y
        : y + baseline - painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    painter.paint(canvas, Offset(centerX - painter.width / 2, top));
  }

  @override
  bool shouldRepaint(TerminalPainter old) =>
      !identical(old.snapshot, snapshot) ||
      old.metrics != metrics ||
      old.palette != palette ||
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
    required this.palette,
    this.focused = true,
    this.onGridChanged,
    this.onTapCell,
    this.onScrolledBack,
    this.onLongPressFocus,
    this.onOpenOptions,
    this.queryTuiActive,
    this.sendTuiPages,
  });

  final ShellSession session;
  final double fontSize;
  final TerminalPalette palette;
  final bool focused;

  /// Reports the measured grid so the view model can open the *next* session at this size.
  final void Function(int cols, int rows)? onGridChanged;
  final void Function(TerminalSnapshot snapshot, int row, int column)? onTapCell;

  /// Called when the user drags back into history.
  ///
  /// A persistent tmux pane holds rows this client never received — tmux collapses output it cannot
  /// keep up with into a repaint — and fetching them costs a round trip, so it is paid for on the
  /// gesture that wants them rather than on every burst of output.
  final void Function()? onScrolledBack;

  /// Focus the touched split pane before showing its transcript and copy actions.
  final VoidCallback? onLongPressFocus;
  final VoidCallback? onOpenOptions;

  /// Asks whether the touched pane owns the alternate screen; regular tmux may need a side query.
  final Future<bool> Function()? queryTuiActive;

  /// Sends capped PageUp/PageDown presses to this pane when its TUI owns scrolling.
  final bool Function(bool up, int count)? sendTuiPages;

  @override
  State<TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<TerminalSurface> with SingleTickerProviderStateMixin {
  /// Fractional rows carried between drag events, so a slow drag still scrolls instead of rounding
  /// every delta down to nothing.
  double _dragRemainder = 0;
  final TuiScrollRouter _router = TuiScrollRouter();
  Timer? _routeIdle;
  int _routeGeneration = 0;
  late final AnimationController _fling;
  double _flingPosition = 0;
  double _flingCellHeight = 1;
  Timer? _resizeTimer;
  (int, int)? _pendingGrid;
  int _layoutRows = 1;

  @override
  void initState() {
    super.initState();
    _fling = AnimationController.unbounded(vsync: this)..addListener(_onFlingTick);
  }

  @override
  void didUpdateWidget(TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _cancelResize();
      _fling.stop();
      _resetRoute();
    }
  }

  @override
  void dispose() {
    _cancelResize();
    _resetRoute();
    _fling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // Kotlin's terminal size is an sp value: Android's system text curve applies, while the
    // separate in-app text preset does not. The app's MediaQuery wraps both scales.
    final scaler = MediaQuery.textScalerOf(context);
    final platformScaler = scaler is OmniTextScaler ? scaler.platform : scaler;
    final android = Theme.of(context).platform == TargetPlatform.android;
    final metrics = TerminalMetrics.measure(
      platformScaler.scale(widget.fontSize),
      fontFamily: android ? 'monospace' : OmniFonts.mono,
      lineHeight: android ? null : 1.2,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      androidMetrics: android,
    );

    return ColoredBox(
      color: widget.palette.background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Kotlin leaves breathing room inside the terminal and reserves the rightmost four
            // percent before telling a remote full-screen application its usable column count.
            final (cols, rows) = metrics.gridFor(
              Size(constraints.maxWidth * .96, constraints.maxHeight),
            );
            _layoutRows = rows;
            // Resizing during layout would mutate state mid-build; the remote is told once the frame
            // this size belongs to has actually been shown.
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (!mounted || widget.session != session) return;
              // Visible ranges track the shown pane immediately; only PTY reflow waits to settle.
              if (session.viewportRows != rows) {
                session.setViewportRows(rows);
                session.publishNow();
              }
              widget.onGridChanged?.call(cols, rows);
              _requestResize(session, cols, rows);
            });

            return ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) => GestureDetector(
                key: const ValueKey('shell.surface'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) {
                  _fling.stop();
                  _dragRemainder = 0;
                },
                onVerticalDragUpdate: (details) => _onDrag(details.delta.dy, metrics.cellHeight),
                onVerticalDragEnd: (details) =>
                    _startFling(details.primaryVelocity ?? 0, metrics.cellHeight),
                onTapUp: (details) => widget.onTapCell?.call(
                  widget.session.snapshot,
                  (details.localPosition.dy / metrics.cellHeight).floor(),
                  (details.localPosition.dx / metrics.cellWidth).floor(),
                ),
                // A painted grid has nothing to select, which left copying output impossible. Long
                // press opens the scrollback as selectable text instead — the Kotlin's answer too.
                onLongPress: () {
                  widget.onLongPressFocus?.call();
                  final open = widget.onOpenOptions;
                  if (open != null) {
                    open();
                  } else {
                    openTerminalTranscript(context, widget.session);
                  }
                },
                // The grid is painted, so it puts nothing in the semantics tree by itself — the app's
                // primary content was unreadable to a screen reader. The label is built from the
                // *viewport* snapshot, which is bounded by the visible rows, so this costs a short
                // string per publish rather than a walk of the scrollback.
                child: Semantics(
                  label: terminalSemanticsLabel(widget.session.snapshot.rows),
                  readOnly: true,
                  child: ClipRect(
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: TerminalPainter(
                        snapshot: widget.session.snapshot,
                        metrics: metrics,
                        palette: widget.palette,
                        showCursor: widget.focused && widget.session.followTail,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _cancelResize() {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _pendingGrid = null;
  }

  void _requestResize(ShellSession session, int cols, int rows) {
    final grid = (cols, rows);
    if (_pendingGrid == grid) return;
    _cancelResize();
    if (session.cols == cols && session.rows == rows) return;
    _pendingGrid = grid;
    // Match Kotlin's settled layout resize: split-handle dragging and IME/rotation frames should
    // not each reflow scrollback and send another remote window-change request.
    _resizeTimer = Timer(const Duration(milliseconds: 120), () {
      _resizeTimer = null;
      _pendingGrid = null;
      if (!mounted || widget.session != session) return;
      session.resize(cols, rows);
    });
  }

  void _onDrag(double dy, double cellHeight) {
    final session = widget.session;
    if (session.readOnly || !session.isOpen) {
      _resetRoute();
      _localDrag(dy, cellHeight);
      return;
    }
    if (widget.queryTuiActive == null || widget.sendTuiPages == null) {
      _localDrag(dy, cellHeight);
      return;
    }
    final routed =
        _router.routedToTui || _router.awaitingResolution || (_router.isIdle && session.followTail);
    if (!routed) {
      _localDrag(dy, cellHeight);
      return;
    }

    final pageSize = math.max(1.0, _layoutRows * cellHeight * 0.8);
    final started = _router.isIdle;
    final action = _router.onDelta(dy, pageSize);
    if (started) _resolveRoute(pageSize, cellHeight, _routeGeneration);
    _applyRoute(action, cellHeight);
    _routeIdle?.cancel();
    _routeIdle = Timer(const Duration(milliseconds: 900), _resetRoute);
  }

  void _startFling(double velocity, double cellHeight) {
    if (velocity.abs() < 50) return;
    _fling.stop();
    _flingPosition = 0;
    _flingCellHeight = cellHeight;
    // The same ballistic continuation as a scrollable viewport: the resulting deltas still pass
    // through the TUI/local router, so a fling cannot silently switch the gesture's destination.
    _fling.animateWith(
      ClampingScrollSimulation(position: 0, velocity: velocity.clamp(-5000.0, 5000.0)),
    );
  }

  void _onFlingTick() {
    final delta = _fling.value - _flingPosition;
    _flingPosition = _fling.value;
    if (delta != 0 && mounted) _onDrag(delta, _flingCellHeight);
  }

  void _resolveRoute(double pageSize, double cellHeight, int generation) {
    unawaited(() async {
      bool tui = false;
      try {
        tui = await widget.queryTuiActive!().timeout(const Duration(milliseconds: 600));
      } catch (_) {
        // A failed side query returns the whole buffered gesture to local history.
      }
      if (!mounted || generation != _routeGeneration) return;
      _applyRoute(_router.resolve(tuiActive: tui, pageSize: pageSize), cellHeight);
    }());
  }

  void _applyRoute(TuiScrollAction action, double cellHeight) {
    switch (action) {
      case BufferedTuiScroll():
        break;
      case LocalTuiScroll(:final delta):
        _localDrag(delta, cellHeight);
      case PageTuiScroll(:final up, :final count):
        if (count > 0) widget.sendTuiPages?.call(up, count);
    }
  }

  void _resetRoute() {
    _routeGeneration++;
    _routeIdle?.cancel();
    _routeIdle = null;
    _router.reset();
  }

  void _localDrag(double dy, double cellHeight) {
    // Dragging down reveals earlier output, the same direction as every other scroll view. The
    // Kotlin settled on tracking the local buffer rather than forwarding wheel events to tmux,
    // because the forwarded version had inconsistent direction and never quite reached the bottom.
    _dragRemainder += -dy / cellHeight;
    final whole = _dragRemainder.truncate();
    if (whole == 0) return;
    _dragRemainder -= whole;
    widget.session.scrollBy(whole);
    if (whole < 0 && widget.session.scrollbackDirty) widget.onScrolledBack?.call();
  }
}
