import 'dart:math' as math;

/// An action for a terminal gesture. Positive deltas reveal older output.
sealed class TuiScrollAction {
  const TuiScrollAction();
}

/// Keep the touch event while the caller queries the remote pane's alternate-screen state.
final class BufferedTuiScroll extends TuiScrollAction {
  const BufferedTuiScroll();
}

/// Replay the delta into local history, including deltas buffered during the query.
final class LocalTuiScroll extends TuiScrollAction {
  const LocalTuiScroll(this.delta);
  final double delta;
}

/// Page the remote full-screen application. A zero count is a consumed sub-page gesture.
final class PageTuiScroll extends TuiScrollAction {
  const PageTuiScroll({required this.up, required this.count});
  final bool up;
  final int count;
}

enum _Route { idle, pending, tui, local }

/// Kotlin's TuiScrollRouter: callers own timers, transport, and read-only session guards.
///
/// Only a gesture beginning at the live tail is eligible. Its first deltas are buffered until
/// the pane query resolves, so a slow SSH response neither loses the gesture nor scrolls a TUI's
/// repaint frames as local history. Reset on session change, query failure, or gesture idle.
class TuiScrollRouter {
  _Route _route = _Route.idle;
  double _buffered = 0;
  double _pageRemainder = 0;

  bool get isIdle => _route == _Route.idle;
  bool get awaitingResolution => _route == _Route.pending;
  bool get routedToTui => _route == _Route.tui;

  TuiScrollAction onDelta(double delta, double pageSize) {
    switch (_route) {
      case _Route.idle:
        _route = _Route.pending;
        _buffered = delta;
        _pageRemainder = 0;
        return const BufferedTuiScroll();
      case _Route.pending:
        _buffered += delta;
        return const BufferedTuiScroll();
      case _Route.local:
        return LocalTuiScroll(delta);
      case _Route.tui:
        return _emitPages(delta, pageSize);
    }
  }

  TuiScrollAction resolve({required bool tuiActive, required double pageSize}) {
    if (!awaitingResolution) return const PageTuiScroll(up: true, count: 0);
    final pending = _buffered;
    _buffered = 0;
    if (tuiActive) {
      _route = _Route.tui;
      return _emitPages(pending, pageSize);
    }
    _route = _Route.local;
    return LocalTuiScroll(pending);
  }

  void reset() {
    _route = _Route.idle;
    _buffered = 0;
    _pageRemainder = 0;
  }

  PageTuiScroll _emitPages(double delta, double pageSize) {
    final effectivePage = math.max(1.0, pageSize);
    _pageRemainder += delta;
    final pages = (_pageRemainder / effectivePage).truncate();
    // Discard excess whole pages, as Kotlin does: a capped burst must not leak into later events.
    _pageRemainder -= pages * effectivePage;
    return PageTuiScroll(up: pages >= 0, count: math.min(3, pages.abs()));
  }
}
