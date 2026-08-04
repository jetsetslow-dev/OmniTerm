import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/ssh/ssh_transport.dart';
import '../../data/term/terminal_emulator.dart';
import '../../data/term/terminal_snapshot.dart';

/// Why a shell session is no longer usable.
///
/// The distinction is the whole point: a remote `exit` is the user finishing, and the session should
/// disappear; a transport drop is the network failing, and the scrollback must stay on screen so the
/// user can read what happened. Both look identical at the stream level — each simply ends the read
/// loop — which is why [TerminalSession.remoteExited] exists as a separate signal.
enum ShellSessionEnd {
  /// Still running.
  open,

  /// The remote shell ran to completion and the server sent a genuine channel EOF.
  remoteExited,

  /// The stream ended without a remote EOF: a dropped socket, a sleeping radio, a killed VPN.
  disconnected,

  /// The user closed it from the app.
  closedByUser,
}

/// One live, app-level SSH terminal: an emulator, a channel, and the viewport onto it.
///
/// Ported from `ShellSession` in `ui/ShellSession.kt`. Per-session rather than global because split
/// panes each own their own PTY geometry and their own scroll position — a pane scrolled up must not
/// drag its neighbour with it.
class ShellSession extends ChangeNotifier {
  ShellSession({
    required this.id,
    required this.serverId,
    required this.serverName,
    required TerminalSession channel,
    required this.emulator,
  }) : _channel = channel {
    _subscription = channel.output.listen(
      _onOutput,
      onError: (Object _) => _finish(ShellSessionEnd.disconnected),
      onDone: _onStreamDone,
      cancelOnError: false,
    );
    channel.closed.addListener(_onChannelClosed);
  }

  final String id;
  final int serverId;
  final String serverName;

  final TerminalSession _channel;

  /// Exposed for the key encoder's DECCKM lookup; input and scrolling go through this class.
  final TerminalEmulator emulator;

  StreamSubscription<Uint8List>? _subscription;

  // ── output publishing ───────────────────────────────────────────────────────

  /// Rebuilds are capped at roughly one display frame.
  ///
  /// Not a nicety: `yes` or a large `cat` delivers hundreds of chunks a second, and notifying per
  /// chunk pegs the UI thread repainting frames nobody can perceive. The emulator still consumes
  /// every byte immediately — only the *painting* is coalesced, so no output is ever skipped.
  static const publishInterval = Duration(milliseconds: 16);

  final Stopwatch _sincePublish = Stopwatch()..start();
  Timer? _publishTimer;

  TerminalSnapshot _snapshot = TerminalSnapshot.empty;
  TerminalSnapshot get snapshot => _snapshot;

  /// Snapshots published so far. Lets a test assert that a burst coalesced rather than guessing.
  int publishCount = 0;

  void _onOutput(Uint8List bytes) {
    if (_disposed) return;
    emulator.feed(bytes);
    _schedulePublish();
  }

  void _schedulePublish() {
    if (_disposed || _publishTimer != null) return;
    final elapsed = _sincePublish.elapsed;
    if (elapsed >= publishInterval) {
      _publish();
      return;
    }
    _publishTimer = Timer(publishInterval - elapsed, () {
      _publishTimer = null;
      _publish();
    });
  }

  void _publish() {
    if (_disposed) return;
    _sincePublish.reset();
    publishCount++;
    _snapshot = emulator.snapshotRange(_viewportFirstRow, viewportRows);
    notifyListeners();
  }

  /// Publish the current grid now, skipping the frame budget.
  ///
  /// Used for state the user just caused (a scroll, a resize), where waiting up to a frame would
  /// feel like lag rather than looking like smoothing.
  void publishNow() {
    _publishTimer?.cancel();
    _publishTimer = null;
    _publish();
  }

  // ── viewport ────────────────────────────────────────────────────────────────

  int _viewportRows = 24;
  int get viewportRows => _viewportRows;

  bool _followTail = true;

  /// True while the viewport is pinned to the newest output.
  bool get followTail => _followTail;

  /// Absolute index of the viewport's top row, counting rows the scrollback has already discarded.
  ///
  /// Absolute rather than buffer-relative so that trimming the scrollback under a scrolled-up
  /// viewport does not slide the content the user is reading. [TerminalEmulator.trimmedRowCount] is
  /// the offset between the two spaces, and exists for exactly this.
  int _anchorRow = 0;

  int get _maxFirstRow => math.max(0, emulator.rowCount() - _viewportRows);

  int get _viewportFirstRow => _followTail
      ? _maxFirstRow
      : (_anchorRow - emulator.trimmedRowCount).clamp(0, _maxFirstRow);

  /// Row index, in buffer space, currently at the top of the view.
  int get viewportFirstRow => _viewportFirstRow;

  /// True when there is history above the viewport to scroll into.
  bool get canScrollBack => _viewportFirstRow > 0;

  /// Move the viewport by [rows] (negative scrolls back into history).
  ///
  /// Reaching the bottom re-arms tail-following, so a user who scrolls up to read and then flicks
  /// back down starts seeing live output again without needing a separate control.
  void scrollBy(int rows) {
    if (rows == 0) return;
    final target = (_viewportFirstRow + rows).clamp(0, _maxFirstRow);
    _setFirstRow(target);
  }

  /// Jump straight back to live output.
  void scrollToTail() => _setFirstRow(_maxFirstRow);

  void _setFirstRow(int target) {
    _followTail = target >= _maxFirstRow;
    _anchorRow = target + emulator.trimmedRowCount;
    publishNow();
  }

  // ── geometry ────────────────────────────────────────────────────────────────

  int _cols = 80;
  int _rows = 24;
  int get cols => _cols;
  int get rows => _rows;

  /// A resize already being negotiated with the remote, and the newest one waiting behind it.
  ///
  /// Newest-wins rather than a queue: rotating the device or opening the keyboard emits a burst of
  /// sizes, and replaying every intermediate one against the remote PTY produces a visible cascade
  /// of reflows for geometry nobody ever saw. Ported from `launchTerminalResizeConsumer`.
  bool _resizing = false;
  (int, int)? _pendingResize;

  /// Tell the session the surface is now [cols]×[rows] cells.
  Future<void> resize(int cols, int rows) async {
    if (cols < 1 || rows < 1) return;
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    _viewportRows = rows;
    emulator.resize(cols, rows);
    publishNow();

    if (_resizing) {
      _pendingResize = (cols, rows);
      return;
    }
    _resizing = true;
    var next = (cols, rows);
    while (true) {
      try {
        await _channel.resize(next.$1, next.$2);
      } catch (_) {
        // A failed resize must not stop the consumer: the next layout change can still recover, and
        // the local grid is already correct either way.
      }
      final pending = _pendingResize;
      if (pending == null || _disposed) break;
      _pendingResize = null;
      next = pending;
    }
    _resizing = false;
  }

  /// Set the viewport height without touching the remote PTY.
  ///
  /// Used before the first real layout, so the initial snapshot is not a 24-row guess.
  void setViewportRows(int rows) {
    if (rows < 1 || rows == _viewportRows) return;
    _viewportRows = rows;
  }

  // ── input ───────────────────────────────────────────────────────────────────

  /// True when this session refuses input, so a shared screen or a fragile host cannot be typed at.
  ///
  /// Enforced here rather than in the widgets: the hardware keyboard, the on-screen key bar and
  /// paste are three separate entry points, and a guard on only some of them is not a guard.
  bool readOnly = false;

  void setReadOnly(bool value) {
    if (value == readOnly) return;
    readOnly = value;
    notifyListeners();
  }

  bool get isOpen => _endReason == ShellSessionEnd.open;

  ShellSessionEnd _endReason = ShellSessionEnd.open;
  ShellSessionEnd get endReason => _endReason;

  int? _exitStatus;
  int? get exitStatus => _exitStatus;

  /// Send raw bytes to the remote PTY.
  ///
  /// Returns false when nothing was sent, so callers can tell "delivered" from "silently dropped" —
  /// a key bar that reports success on a dead session teaches the user to distrust the whole screen.
  bool write(Uint8List bytes) {
    if (_disposed || !isOpen || readOnly || bytes.isEmpty) return false;
    // Typing is an implicit "show me the bottom": every terminal behaves this way, and reading old
    // output while your keystrokes land somewhere off-screen is disorienting.
    if (!_followTail) scrollToTail();
    unawaited(_write(bytes));
    return true;
  }

  Future<void> _write(Uint8List bytes) async {
    try {
      await _channel.write(bytes);
    } catch (_) {
      // The channel's own close signal decides the session's fate; a failed write is a symptom.
    }
  }

  // ── lifecycle ───────────────────────────────────────────────────────────────

  void _onStreamDone() {
    // `remoteExited` is the transport's judgement, already made by `classifyTerminalClose`. An ended
    // stream on its own says nothing: a dropped socket ends it exactly as `exit` does.
    _finish(_channel.remoteExited.value
        ? ShellSessionEnd.remoteExited
        : ShellSessionEnd.disconnected);
  }

  void _onChannelClosed() {
    if (_channel.closed.value) _onStreamDone();
  }

  /// Close from the app side.
  void closeByUser() => _finish(ShellSessionEnd.closedByUser);

  void _finish(ShellSessionEnd reason) {
    if (_disposed || _endReason != ShellSessionEnd.open) return;
    _endReason = reason;
    _exitStatus = _channel.exitStatus.value;
    _channel.closed.removeListener(_onChannelClosed);
    unawaited(_subscription?.cancel());
    _subscription = null;
    try {
      _channel.close();
    } catch (_) {
      // Closing an already-dead channel is normal here; there is nothing left to recover.
    }
    // Show whatever arrived before the end, including a shutdown message the remote managed to
    // print: a session that blanks on disconnect destroys the only evidence of why.
    publishNow();
  }

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _publishTimer?.cancel();
    _publishTimer = null;
    _channel.closed.removeListener(_onChannelClosed);
    unawaited(_subscription?.cancel());
    _subscription = null;
    try {
      _channel.close();
    } catch (_) {
      // Same as above: disposal must not throw on a channel the network already took away.
    }
    super.dispose();
  }
}
