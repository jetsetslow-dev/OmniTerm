import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/ssh/ssh_transport.dart';
import '../../data/term/terminal_emulator.dart';
import '../../data/term/tmux_control_commands.dart';
import '../../data/term/tmux_control_event.dart';
import '../../data/term/tmux_control_parser.dart';
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
    this.tmuxName,
    this.controlMode = false,
    DateTime? startedAt,
  }) : _channel = channel,
       startedAt = startedAt ?? DateTime.now(),
       _control = controlMode ? TmuxControlParser() : null {
    _listenTo(channel);
  }

  final String id;
  final int serverId;
  final String serverName;

  /// When this session was opened, for the age shown beside it.
  ///
  /// Injectable so a test can pin it: an age derived from `DateTime.now()` at construction is
  /// otherwise untestable without waiting real minutes.
  final DateTime startedAt;

  /// The tmux session this terminal is attached to, when the host is persistent.
  ///
  /// Held so the resumable list can tell "already open in a tab" from "still running on the server
  /// with nobody watching" — offering to resume a session the user is currently looking at would be
  /// nonsense.
  final String? tmuxName;

  /// True when the remote was attached with `tmux -C`, so the channel carries a control-mode
  /// conversation rather than raw terminal bytes.
  ///
  /// This is what makes fast output safe: tmux streams **every** pane byte as a `%output` event
  /// instead of redrawing a client, so output the user has not seen yet cannot be collapsed into a
  /// repaint. Nothing else about the terminal changes — the bytes carried inside those events go to
  /// the same emulator.
  final bool controlMode;

  /// Splits the control-mode conversation into events. Null for an ordinary attach.
  TmuxControlParser? _control;

  /// Why tmux said the session ended, when it said anything.
  String? controlExitReason;

  TerminalSession _channel;

  bool reconnecting = false;
  String? reconnectError;

  /// Replace a dropped transport without replacing this tab, its scrollback, or split ownership.
  bool reconnectWith(TerminalSession channel) {
    if (_disposed || _endReason != ShellSessionEnd.disconnected || channel.closed.value) {
      return false;
    }
    _channel = channel;
    _control = controlMode ? TmuxControlParser() : null;
    _commandsSent = 0;
    _repliesSeen = 0;
    _controlPaneId = null;
    _paneChangeRevision++;
    paneChangePending = false;
    controlExitReason = null;
    _endReason = ShellSessionEnd.open;
    _exitStatus = null;
    reconnecting = false;
    reconnectError = null;
    controlRefreshError = null;
    scrollbackDirty = tmuxName != null;
    _listenTo(channel);
    publishNow();
    return true;
  }

  void _listenTo(TerminalSession channel) {
    // A cancelled subscription can still have asynchronous work in flight. Only the current
    // transport owns output and closure; an old channel must never finish its replacement.
    _subscription = channel.output.listen(
      (bytes) {
        if (identical(channel, _channel) && isOpen) _onOutput(bytes);
      },
      onError: (Object _) {
        if (identical(channel, _channel)) _finish(ShellSessionEnd.disconnected);
      },
      onDone: () {
        if (identical(channel, _channel)) _onStreamDone();
      },
    );
    channel.closed.addListener(_onChannelClosed);
  }

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
    // Output arriving while the user is reading history is exactly when tmux's collapsing can have
    // left the local copy short. Armed here rather than on every byte so a session at the tail —
    // where the user can see what arrived — never pays for a capture.
    if (!_followTail) scrollbackDirty = true;

    final control = _control;
    if (control == null) {
      emulator.feed(bytes);
      _schedulePublish();
      return;
    }

    for (final event in control.feed(bytes)) {
      switch (event) {
        // Only pane output is terminal content. A reply, a notification or a session change is the
        // protocol talking about itself, and feeding it to the emulator would paint tmux's own
        // bookkeeping into the user's scrollback.
        case TmuxOutput(:final paneId, :final data):
          // The pane tmux is streaming is also the pane keystrokes must be addressed to. Learning it
          // from the output rather than from a `list-panes` round trip means input works from the
          // first byte the session receives.
          _controlPaneId ??= paneId;
          // A control client receives output from background panes too. Match Kotlin's active
          // pane filter so another window's output cannot corrupt the visible terminal.
          if (paneId == _controlPaneId) emulator.feed(data);
        case TmuxExit(:final reason):
          controlExitReason = reason;
          // %exit ends a *client*, not necessarily its persistent tmux session. Let the owner
          // probe the exact saved name before deciding whether recovery metadata can be removed.
          _finish(tmuxName != null ? ShellSessionEnd.disconnected : ShellSessionEnd.remoteExited);
          return;
        // Resolve the input pane on the initial attach too. An existing quiet shell need not
        // emit any %output, so waiting for output would make reattached terminals ignore input.
        case TmuxSessionChanged():
          _notePaneChange();
        case TmuxNotification(:final line):
          if (_paneChanging.hasMatch(line)) _notePaneChange();
        case TmuxReply(:final flags):
          if (flags & 1 != 0) {
            final waiter = _controlReplies.remove(++_repliesSeen);
            if (waiter != null) {
              if (event.isError) {
                waiter.completeError(StateError('tmux: ${event.body}'));
              } else {
                waiter.complete(event.body);
              }
            }
          }
      }
    }
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

  int get _viewportFirstRow =>
      _followTail ? _maxFirstRow : (_anchorRow - emulator.trimmedRowCount).clamp(0, _maxFirstRow);

  /// Row index, in buffer space, currently at the top of the view.
  int get viewportFirstRow => _viewportFirstRow;

  /// True when there is history above the viewport to scroll into.
  bool get canScrollBack => _viewportFirstRow > 0;

  /// True when output has landed since the local scrollback was last known to match the pane's.
  ///
  /// Only meaningful for a persistent tmux session. tmux collapses output the client cannot keep up
  /// with into a repaint, so a burst leaves the local scrollback missing rows the pane still holds;
  /// this marks that the two may have diverged, and a scroll into history is what pays to find out.
  bool scrollbackDirty = false;

  /// Replaces the buffered scrollback with [source]'s, keeping the live screen, and returns the
  /// change in row count.
  ///
  /// The anchor moves with the content: adopting a longer history pushes what the user is reading
  /// further down the buffer, and without the shift the viewport would appear to jump. Kotlin does
  /// the same at `ui/AppViewModel.kt:5023`.
  int adoptScrollback(TerminalEmulator source) {
    final before = emulator.scrollbackRowCount();
    emulator.adoptScrollbackFrom(source);
    final delta = emulator.scrollbackRowCount() - before;
    if (delta != 0 && !_followTail) _anchorRow += delta;
    scrollbackDirty = false;
    publishNow();
    return delta;
  }

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

  /// Drops the buffered scrollback, keeping the live screen.
  ///
  /// Ported from `clearTerminalScrollbackFor` (`ui/ShellScreen.kt:2513`). The emulator has always
  /// been able to do this, but nothing in the port called it except the DECSTR escape handler, so
  /// the only way to drop buffered output was to end the session — and with a persistent tmux
  /// session, not even that.
  ///
  /// The viewport is snapped back to the tail because every row it might have been anchored to is
  /// gone; leaving it where it was would show a blank region above the live screen.
  void clearScrollback() {
    emulator.clearScrollback();
    scrollToTail();
    publishNow();
  }

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
      final channel = _channel;
      try {
        await channel.resize(next.$1, next.$2);
        // Control mode also needs telling explicitly: tmux sizes a control client from
        // `refresh-client -C`, so without this the panes keep the geometry they were attached at
        // and output wraps against the old width. Kotlin does the same at `AppViewModel.kt:5970`.
        if (identical(channel, _channel) && isOpen && controlMode && _controlPaneId != null) {
          await _sendControlLines([TmuxControlCommands.refreshClientSize(next.$1, next.$2)]);
        }
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
    if (value && _pendingInput.isNotEmpty) {
      _pendingInput.clear();
      controlRefreshError = 'Held input was cancelled because this terminal is now read-only.';
    }
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
    if (controlMode && (_controlPaneId == null || paneChangePending)) {
      // Hold input across pane discovery/repaint, never send raw keys as tmux commands or to the
      // old pane. Bound pasted input while a remote is unresponsive.
      if (_pendingInput.length + bytes.length > 65536) {
        controlRefreshError =
            'Input buffer is full while the tmux pane loads. This input was not sent.';
        publishNow();
        return false;
      }
      _pendingInput.addAll(bytes);
      return true;
    }
    // Typing is an implicit "show me the bottom": every terminal behaves this way, and reading old
    // output while your keystrokes land somewhere off-screen is disorienting.
    if (!_followTail) scrollToTail();
    unawaited(_write(bytes));
    return true;
  }

  /// The pane tmux is streaming, in control mode. Null until the first `%output`.
  String? _controlPaneId;

  /// The pane keystrokes are addressed to, exposed for tests.
  @visibleForTesting
  String? get controlPaneId => _controlPaneId;

  /// Bumped every time tmux says the active pane may have moved.
  ///
  /// The refresh reads this before its query and again after, and restarts when it changed: a
  /// second switch arriving while the first is still resolving must not be answered with the
  /// first one's pane id.
  int _paneChangeRevision = 0;

  int get paneChangeRevision => _paneChangeRevision;

  /// True once tmux has reported a pane change that has not been resolved yet.
  bool paneChangePending = false;
  bool controlRefreshing = false;
  String? controlRefreshError;
  final _pendingInput = <int>[];

  /// Adopt a pane id resolved out of band, from `tmux display-message -p '#{pane_id}'`.
  ///
  /// Refused when the revision moved on, because by then the answer describes a pane the user has
  /// already left — the same reason Kotlin re-checks its revision before committing
  /// (`ui/AppViewModel.kt:5158`).
  bool adoptControlPane(String paneId, int revision) {
    if (_disposed || revision != _paneChangeRevision) return false;
    _controlPaneId = paneId;
    paneChangePending = false;
    scrollbackDirty = true;
    if (_pendingInput.isNotEmpty) {
      final bytes = Uint8List.fromList(_pendingInput);
      _pendingInput.clear();
      write(bytes);
    }
    return true;
  }

  int _commandsSent = 0;
  int _repliesSeen = 0;
  final _controlReplies = <int, Completer<String>>{};

  Future<void> _sendControlLines(List<String> lines) {
    if (_disposed || !isOpen) throw StateError('Terminal disconnected');
    _commandsSent += lines.length;
    return _channel.write(Uint8List.fromList(utf8.encode('${lines.join('\n')}\n')));
  }

  /// Every command (including input/resize) participates in reply ordering. Only awaited replies
  /// allocate storage. The attach reply has flag 0 and must not consume a client-command slot.
  Future<String> _controlCommand(String command) async {
    if (_disposed || !isOpen) throw StateError('Terminal disconnected');
    final channel = _channel;
    final ordinal = _commandsSent + 1;
    final reply = Completer<String>();
    _controlReplies[ordinal] = reply;
    // Attach the error handler before writing: an immediate disconnect may fail all waiters.
    final result = reply.future.timeout(const Duration(seconds: 5));
    try {
      unawaited(
        _sendControlLines([command]).catchError((Object error) {
          if (!reply.isCompleted) reply.completeError(error);
          if (identical(channel, _channel)) _finish(ShellSessionEnd.disconnected);
        }),
      );
      return await result;
    } on TimeoutException {
      // A client stuck while paused must detach, not leave a permanently frozen screen. A late
      // reply on this transport must never complete a command on its replacement.
      if (identical(channel, _channel)) _finish(ShellSessionEnd.disconnected);
      rethrow;
    } finally {
      if (identical(_controlReplies[ordinal], reply)) _controlReplies.remove(ordinal);
    }
  }

  /// Seed a quiet pane before enabling input. Pause/continue are client-local, and replies arrive
  /// on the same ordered stream as pane output, so pre-capture output cannot overtake the repaint.
  Future<bool> repaintControlPane(String paneId, int revision) async {
    final channel = _channel;
    bool ownsPane() =>
        !_disposed && isOpen && identical(channel, _channel) && revision == _paneChangeRevision;
    if (!ownsPane()) return false;
    paneChangePending = true;
    await _controlCommand(TmuxControlCommands.refreshClientSize(cols, rows));
    if (!ownsPane()) return false;
    try {
      await _controlCommand(TmuxControlCommands.paneOutputState(paneId, 'pause'));
      if (!ownsPane()) return false;
      final width = cols;
      final height = rows;
      final screen = await _controlCommand(TmuxControlCommands.capturePaneScreen(paneId));
      final cursor = await _controlCommand(TmuxControlCommands.paneCursorQuery(paneId));
      if (!ownsPane() || width != cols || height != rows) return false;
      final xy = cursor.trim().split(RegExp(r'\s+'));
      final x = xy.length == 2 ? int.tryParse(xy[0]) : null;
      final y = xy.length == 2 ? int.tryParse(xy[1]) : null;
      if (x == null || y == null || x < 0 || y < 0 || x >= width || y >= height) {
        throw StateError('tmux returned an invalid cursor position');
      }
      _controlPaneId = paneId;
      emulator.feed(
        Uint8List.fromList(
          utf8.encode(
            '\x1b[r\x1b[0m\x1b[2J\x1b[H${screen.replaceAll('\n', '\r\n')}'
            '\x1b[${y + 1};${x + 1}H\x1b[0m',
          ),
        ),
      );
      publishNow();
    } finally {
      if (!_disposed && isOpen && identical(channel, _channel)) {
        try {
          await _controlCommand(TmuxControlCommands.paneOutputState(paneId, 'continue'));
        } catch (_) {
          if (identical(channel, _channel)) _finish(ShellSessionEnd.disconnected);
          rethrow;
        }
      }
    }
    return ownsPane() && adoptControlPane(paneId, revision);
  }

  /// tmux notifications that mean "the pane your keystrokes are addressed to may have moved".
  ///
  /// `%output` cannot carry this: it names the pane that *produced* output, and a background pane
  /// producing output would steal the keyboard if it were treated as the active one.
  static final _paneChanging = RegExp(
    r'^%(window-pane-changed|session-window-changed|client-session-changed|window-close|window-add|unlinked-window-close)\b',
  );

  void _notePaneChange() {
    _paneChangeRevision++;
    paneChangePending = true;
    onPaneChanged?.call(this);
  }

  /// Invoked when the active pane may have moved; the view model does the side-channel query.
  void Function(ShellSession session)? onPaneChanged;

  Future<void> _write(Uint8List bytes) async {
    final channel = _channel;
    try {
      if (controlMode) {
        await _sendControlLines(TmuxControlCommands.sendKeysHex(_controlPaneId!, bytes));
      } else {
        await channel.write(bytes);
      }
    } catch (_) {
      // A write can fail before the output stream notices the dead socket. Marking the session
      // disconnected here prevents further keystrokes from being accepted and gives the terminal
      // an immediate visible "Connection lost" state instead of silently dropping input.
      if (identical(channel, _channel)) _finish(ShellSessionEnd.disconnected);
    }
  }

  // ── lifecycle ───────────────────────────────────────────────────────────────

  void _onStreamDone() {
    // `remoteExited` is the transport's judgement, already made by `classifyTerminalClose`. An ended
    // stream on its own says nothing: a dropped socket ends it exactly as `exit` does.
    _finish(
      _channel.remoteExited.value ? ShellSessionEnd.remoteExited : ShellSessionEnd.disconnected,
    );
  }

  void _onChannelClosed() {
    if (_channel.closed.value) _onStreamDone();
  }

  /// Close from the app side.
  void closeByUser() => _finish(ShellSessionEnd.closedByUser);

  void _finish(ShellSessionEnd reason) {
    if (_disposed || _endReason != ShellSessionEnd.open) return;
    _endReason = reason;
    _failControlReplies();
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

  void _failControlReplies() {
    for (final reply in _controlReplies.values) {
      if (!reply.isCompleted) reply.completeError(StateError('Terminal disconnected'));
    }
    _controlReplies.clear();
    // Never replay uncertain keystrokes after reconnect.
    _pendingInput.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failControlReplies();
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
