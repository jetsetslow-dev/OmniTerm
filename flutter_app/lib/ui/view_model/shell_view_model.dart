import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/ssh/dartssh_transport.dart' show SshHostKeyException;
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../data/term/terminal_emulator.dart';
import '../../data/term/tmux_bootstrap.dart';
import '../../domain/app_preferences.dart';
import '../../domain/server_credentials.dart';
import '../../domain/terminal_key_encoder.dart';
import '../../platform/session_service.dart';
import 'app_state.dart';
import 'shell_session.dart';

/// The Shell screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Owns the open sessions, which one is focused, the sticky modifier keys, and the one path every
/// keystroke takes to the remote. Splitting input through here rather than through the widgets is
/// what makes the read-only guard and the modifier rules testable without a terminal on screen.
class ShellViewModel extends ChangeNotifier {
  ShellViewModel(this._app, {this.transport, this.sessionService}) {
    _app.addListener(_onAppChanged);
    // Read once at construction rather than watched: rows change only when this view model writes
    // them, and it reloads itself when it does.
    unawaited(_reloadSaved());
    final service = sessionService;
    if (service != null) {
      _actionsSub = service.actions.listen(_onServiceAction, onError: (Object _) {});
    }
  }

  final AppState _app;

  /// Null in tests and in any build without a transport wired. Connecting then reports that the
  /// terminal is unavailable rather than opening a screen that will never receive a byte
  /// (Convention 4).
  final SshTransport? transport;

  bool get canConnect => transport != null;

  /// Keeps the process alive while sessions are open in the background. Null in tests and on
  /// platforms without one — sessions then simply do not survive the app being backgrounded, which
  /// is the platform's behaviour rather than something the app can pretend away.
  final SessionService? sessionService;

  StreamSubscription<SessionServiceAction>? _actionsSub;

  /// The shade acts on the sessions this view model owns, so its buttons come back here rather
  /// than being handled natively — the service has no way to close a channel living in Dart.
  void _onServiceAction(SessionServiceAction action) {
    switch (action) {
      case DisconnectSession(:final sessionId):
        final session = _sessions.where((s) => s.id == sessionId).firstOrNull;
        if (session != null) close(session);
      case DisconnectAllSessions():
        for (final session in _sessions.toList()) {
          close(session);
        }
      case ResumeSession(:final sessionId):
        if (_sessions.any((s) => s.id == sessionId)) select(sessionId);
    }
  }

  /// Tell the platform which sessions are open.
  ///
  /// Called after every change to the list rather than only on backgrounding: the notification is
  /// the user's view of what this app is holding open, and one that lags reality is worse than none.
  void _syncBackgroundSessions() {
    unawaited(
      sessionService?.sync([
        for (final session in _sessions)
          if (session.isOpen) BackgroundSession(id: session.id, serverName: session.serverName),
      ]),
    );
  }

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _onAppChanged() => _safeNotify();

  // ── the host this screen is about ───────────────────────────────────────────

  /// Hosts offered for a *new* connection.
  ///
  /// Online only, matching the other live tabs. Forcing SSH to a host the app believes is down is
  /// done from the Hosts tab's connect button, which warns first — offering it here as an ordinary
  /// choice would hide that warning.
  List<Server> get connectableServers => _app.servers.where((s) => s.status == 'online').toList();

  /// The host the screen is showing.
  ///
  /// The focused session's host wins, because the header must name exactly the terminal on screen.
  /// Falling back to the selected host while a session is open made the header actively misleading.
  Server? get server {
    final session = current;
    if (session != null) {
      final owner = _app.servers.where((s) => s.id == session.serverId).firstOrNull;
      if (owner != null) return owner;
    }
    final online = connectableServers;
    return online.where((s) => s.id == _app.selectedServerId).firstOrNull ??
        (online.isNotEmpty ? online.first : null);
  }

  /// Whether any host is saved at all.
  ///
  /// Distinct from [connectableServers] being empty: "no hosts" and "no hosts *online*" are
  /// different problems with different fixes, and one message for both sends the user to the wrong
  /// place.
  bool get hasAnyHost => _app.servers.isNotEmpty;

  /// True when there is nothing to show and nothing to connect to.
  bool get hasNothingToShow => server == null && sessions.isEmpty && !isConnecting;

  // ── sessions ────────────────────────────────────────────────────────────────

  final List<ShellSession> _sessions = [];
  List<ShellSession> get sessions => List.unmodifiable(_sessions);

  String? _currentId;

  ShellSession? get current =>
      _sessions.where((s) => s.id == _currentId).firstOrNull ??
      (_sessions.isNotEmpty ? _sessions.last : null);

  void select(String id) {
    if (_currentId == id) return;
    _currentId = id;
    _safeNotify();
  }

  // ── split view ──────────────────────────────────────────────────────────────

  /// The session shown in the second pane, or null when the view is single.
  ///
  /// Held as an id rather than a `ShellSession` so a session that ends while split simply stops
  /// resolving — [splitSession] returns null and the view falls back to single, instead of the
  /// screen holding a reference to a terminal that no longer exists.
  String? _splitId;

  /// True when the panes stack vertically. The Kotlin calls these `⬍ STACK` and `⬌ COLS`.
  bool _splitStacked = true;
  bool get splitStacked => _splitStacked;

  ShellSession? get splitSession =>
      _splitId == null ? null : _sessions.where((s) => s.id == _splitId).firstOrNull;

  bool get isSplit => splitSession != null && current != null && splitSession != current;

  /// Sessions that could occupy the second pane: everything except the one already in the first.
  List<ShellSession> get splitCandidates => _sessions.where((s) => s.id != current?.id).toList();

  /// Shows [id] in the second pane.
  void splitWith(String id) {
    if (id == current?.id) return;
    _splitId = id;
    _safeNotify();
  }

  void unsplit() {
    if (_splitId == null) return;
    _splitId = null;
    _safeNotify();
  }

  void toggleSplitAxis() {
    _splitStacked = !_splitStacked;
    _safeNotify();
  }

  /// Focuses the pane showing [id].
  ///
  /// Focus is what every per-session action targets — keystrokes, the key bar, disconnect — so in
  /// split view "the current session" has to mean "the pane the user last touched", not whichever
  /// pane happens to be first.
  void focusPane(String id) {
    if (!_sessions.any((s) => s.id == id)) return;
    if (id == _currentId) return;
    // Swap rather than replace: the pane being focused becomes the primary, and the one that was
    // primary keeps its place in the split instead of vanishing.
    if (id == _splitId) _splitId = _currentId;
    _currentId = id;
    _safeNotify();
  }

  bool _connecting = false;
  bool get isConnecting => _connecting;

  String? _phase;

  /// Human-readable connection progress ("Authenticating…"), straight from the transport.
  String? get connectPhase => _phase;

  String? _error;
  String? get error => _error;

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  /// Decides which tmux session a connection to [server] should join, creating a row if needed.
  ///
  /// [resumeName] forces a specific session — that is what the resumable list passes, so tapping a
  /// remembered session joins *that* one rather than whichever row happens to be newest.
  Future<(String name, String command)> _persistentTarget(
    Server server, {
    String? resumeName,
    bool controlMode = false,
  }) async {
    final scrollback = PreferenceLimits.terminalScrollback.parse(
      await _app.repository.getSetting('terminal_scrollback_limit'),
    );
    final rows = (await _app.repository.getPersistentSessions())
        .where((row) => row.serverId == server.id)
        .toList();
    final existing = resumeName ?? (rows.isEmpty ? null : rows.last.tmuxName);

    if (existing != null) {
      // Resume, not plain attach. A remembered row outlives the server rebooting, and a plain
      // attach to a session that is gone silently leaves an ordinary, non-persistent shell.
      return (
        existing,
        tmuxResumeCommand(existing, historyLimit: scrollback, controlMode: controlMode),
      );
    }

    final name = tmuxSafeName('omniterm-${server.id}-${DateTime.now().millisecondsSinceEpoch}');
    await _app.repository.upsertPersistentSession(
      PersistentSessionsCompanion.insert(
        tmuxName: name,
        serverId: server.id,
        serverName: server.name,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        // Only meaningful once the session is actually left running in the background; the
        // "backgrounded since" clock starts there, not here.
        backgroundedAt: 0,
      ),
    );
    return (
      name,
      controlMode
          ? tmuxControlCreateAttachCommand(name, historyLimit: scrollback)
          : tmuxCreateAttachCommand(name, historyLimit: scrollback),
    );
  }

  // ── resumable sessions ──────────────────────────────────────────────────────

  List<PersistentSession> _saved = const [];

  /// Sessions left running on a server that are **not** open in a tab here.
  ///
  /// The filter is the point: offering to resume a session the user is currently looking at would
  /// be nonsense, and hiding one they left running would lose it.
  List<PersistentSession> get resumableSessions =>
      List.unmodifiable(_saved.where((row) => _sessions.every((s) => s.tmuxName != row.tmuxName)));

  /// Removes a saved session from this device.
  ///
  /// **Does not touch the server.** The tmux session keeps running; this only forgets the pointer,
  /// which is why the button says "Forget" rather than "Close".
  Future<void> forgetResumable(PersistentSession row) async {
    await _app.repository.deletePersistentSession(row.tmuxName);
    await _reloadSaved();
  }

  /// Opens a saved session again, attaching to that exact tmux name.
  Future<void> resume(PersistentSession row) async {
    final server = _app.servers.where((s) => s.id == row.serverId).firstOrNull;
    if (server == null) {
      _error = 'The host this session ran on is no longer saved.';
      _safeNotify();
      return;
    }
    await connect(server, resumeName: row.tmuxName);
  }

  /// Stamps when [tmuxName] stopped being watched.
  ///
  /// Read-then-write rather than a partial update: the row carries the host it belongs to, and
  /// rewriting it from anything but itself would be how a session ends up attributed to the wrong
  /// machine.
  Future<void> _markBackgrounded(String tmuxName) async {
    final row = (await _app.repository.getPersistentSessions())
        .where((r) => r.tmuxName == tmuxName)
        .firstOrNull;
    if (row == null) return;
    await _app.repository.upsertPersistentSession(
      PersistentSessionsCompanion.insert(
        tmuxName: row.tmuxName,
        serverId: row.serverId,
        serverName: row.serverName,
        createdAt: row.createdAt,
        backgroundedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _reloadSaved();
  }

  /// Re-reads the saved sessions.
  ///
  /// Public because the list can change without this view model writing it — another device, a
  /// restored backup — and the Shell screen refreshes when it is shown rather than trusting a
  /// snapshot taken at construction.
  Future<void> refreshResumable() => _reloadSaved();

  Future<void> _reloadSaved() async {
    _saved = await _app.repository.getPersistentSessions();
    _safeNotify();
  }

  /// Whether the next connection to a persistent host attaches with `tmux -C`.
  ///
  /// A per-connection choice rather than a stored host setting: it changes how this app reads the
  /// channel, not anything about the server, and a wrong guess is undone by reconnecting.
  bool _useControlMode = false;

  bool get useControlMode => _useControlMode;

  set useControlMode(bool value) {
    if (_useControlMode == value) return;
    _useControlMode = value;
    notifyListeners();
  }

  /// Open a new shell on [server].
  ///
  /// [controlMode] attaches a persistent host with `tmux -C` instead of an ordinary client. It is
  /// opt-in rather than the default because this app renders one pane: control mode's window and
  /// layout events are parsed and ignored, so a session that is split *inside* tmux would show only
  /// the pane whose output arrives. For a single pane it is strictly better — every byte is
  /// delivered as an event rather than folded into a redraw — which is why it is offered at all.
  Future<void> connect(Server server, {String? resumeName, bool controlMode = false}) async {
    if (_connecting) return;
    final ssh = transport;
    if (ssh == null) {
      _error = 'The terminal is unavailable in this build: no SSH transport is wired.';
      _safeNotify();
      return;
    }

    _connecting = true;
    _phase = 'Connecting…';
    _error = null;
    _safeNotify();

    try {
      // The same bound the Settings screen enforces, applied again on read: a hand-edited or
      // corrupt row must not be allowed to allocate a scrollback that exhausts the device.
      final scrollbackLimit = PreferenceLimits.terminalScrollback.parse(
        await _app.repository.getSetting('terminal_scrollback_limit'),
      );
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      // Connect at the size the surface is already showing, so the remote's first prompt is drawn
      // for the real window. Opening at 80×24 and resizing afterwards makes every shell redraw and
      // leaves full-screen apps briefly wrong.
      final channel = await ssh.openShell(
        creds,
        _preferredCols,
        _preferredRows,
        onPhaseChange: (phase) {
          if (_disposed) return;
          _phase = phase;
          _safeNotify();
        },
      );
      if (_disposed) {
        channel.close();
        return;
      }
      final emulator = TerminalEmulator(
        cols: _preferredCols,
        rows: _preferredRows,
        scrollbackLimit: scrollbackLimit,
      );
      // Resolved before the session is built so it can carry its own tmux name — that is what
      // lets the resumable list tell "open in a tab" from "running with nobody watching".
      final persistent = server.persistentSession
          ? await _persistentTarget(server, resumeName: resumeName, controlMode: controlMode)
          : null;

      final session = ShellSession(
        id: '${DateTime.now().microsecondsSinceEpoch}-${server.id}',
        serverId: server.id,
        serverName: server.name,
        channel: channel,
        emulator: emulator,
        tmuxName: persistent?.$1,
        // Only a host that actually went into tmux can be in control mode; a plain shell that was
        // asked for it would have its ordinary output parsed as a protocol and rendered as nothing.
        controlMode: controlMode && persistent != null,
      )..setViewportRows(_preferredRows);
      session.addListener(_safeNotify);
      session.addListener(_syncBackgroundSessions);
      _sessions.add(session);
      _currentId = session.id;

      // A host marked "persistent" is put inside tmux immediately, which is the whole point: a
      // dropped link then leaves the work running on the server instead of killing it. Written as
      // the shell's first input rather than run as a channel command, so a host without tmux is
      // left at a perfectly ordinary prompt (the command guards itself with `command -v tmux`).
      if (persistent != null) {
        session.write(Uint8List.fromList(utf8.encode(persistent.$2)));
        await _reloadSaved();
      }
      _syncBackgroundSessions();
    } on CredentialResolutionException catch (e) {
      _error = e.message;
    } on SshHostKeyException catch (e) {
      // Named separately from an auth failure because the fix is different and the stakes are
      // different: "wrong password" is a nuisance, "this host's key changed" is either a rebuilt
      // server or someone standing between you and it, and the app must not blur the two.
      _error = switch (e.verdict) {
        HostKeyVerdict.changed =>
          'The host key for ${server.name} has CHANGED. This is what a machine-in-the-middle looks '
              'like. If you rebuilt or replaced this server, remove its pinned key under '
              'Tools › Auth & keys and connect again — otherwise do not.',
        _ =>
          'The host key for ${server.name} was not accepted, so the connection was refused. '
              'Connect again to see the fingerprint prompt.',
      };
    } on SshConnectException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Could not open a shell on ${server.name}: $e';
    } finally {
      _connecting = false;
      _phase = null;
      _safeNotify();
    }
  }

  /// Close and forget a session.
  ///
  /// For a persistent host this is *not* the end of the work: the tmux session keeps running on the
  /// server, which is the entire point of marking a host persistent. So closing the tab starts that
  /// session's "left running since" clock — without it the resumable list cannot tell a session
  /// abandoned two minutes ago from one abandoned last month, and Forget is a decision made blind.
  void close(ShellSession session) {
    final tmuxName = session.tmuxName;
    if (tmuxName != null) unawaited(_markBackgrounded(tmuxName));
    session.closeByUser();
    session.removeListener(_safeNotify);
    session.removeListener(_syncBackgroundSessions);
    _sessions.remove(session);
    if (_splitId == session.id) _splitId = null;
    if (_currentId == session.id) _currentId = _sessions.isEmpty ? null : _sessions.last.id;
    session.dispose();
    _syncBackgroundSessions();
    _safeNotify();
  }

  /// Drop a session that ended on its own.
  ///
  /// Kept separate from [close] because the two are different events to the user: this one is the
  /// app acknowledging something that already happened, and the scrollback stays readable until
  /// they dismiss it.
  void dismissEnded(ShellSession session) {
    if (session.isOpen) return;
    close(session);
  }

  // ── grid size ───────────────────────────────────────────────────────────────

  int _preferredCols = 80;
  int _preferredRows = 24;

  /// Remember the surface's measured grid, so the *next* connect opens at the right size.
  void rememberGrid(int cols, int rows) {
    if (cols < 1 || rows < 1) return;
    _preferredCols = cols;
    _preferredRows = rows;
  }

  // ── sticky modifiers ────────────────────────────────────────────────────────

  /// Ctrl/Alt/Shift are one-shot: they arm, apply to the next key, and clear.
  ///
  /// A touch keyboard cannot hold a key down, so the alternative is a latch the user has to
  /// remember to turn off — and a forgotten latch turns the next `l` into a screen-clearing ^L.
  bool ctrl = false;
  bool alt = false;
  bool shift = false;

  bool get hasModifier => ctrl || alt || shift;

  void toggleCtrl() {
    ctrl = !ctrl;
    _safeNotify();
  }

  void toggleAlt() {
    alt = !alt;
    _safeNotify();
  }

  void toggleShift() {
    shift = !shift;
    _safeNotify();
  }

  void _clearModifiers() {
    if (!hasModifier) return;
    ctrl = false;
    alt = false;
    shift = false;
    _safeNotify();
  }

  // ── input ───────────────────────────────────────────────────────────────────

  /// Send a special key.
  ///
  /// Returns false when nothing was sent — no session, a dead one, or read-only. Paging is the one
  /// thing read-only still allows, because it only moves the local viewport.
  bool sendKey(TermKey key) {
    final session = current;
    if (session == null) return false;

    if (session.readOnly) {
      if (!terminalKeyAllowedInReadOnly(key)) return false;
      _scrollByPage(session, key == TermKey.pageUp ? -1 : 1);
      return true;
    }

    final bytes = TerminalKeyEncoder.encode(
      key,
      applicationCursorKeys: session.emulator.applicationCursorKeys,
      shift: shift,
      alt: alt,
      ctrl: ctrl,
    );
    final sent = session.write(bytes);
    _clearModifiers();
    return sent;
  }

  /// Send typed text under the current modifiers.
  bool typeText(String text) {
    final session = current;
    if (session == null || text.isEmpty) return false;
    final bytes = encodeTypedText(text, shift: shift, alt: alt, ctrl: ctrl);
    final sent = session.write(bytes);
    _clearModifiers();
    return sent;
  }

  /// Send a clipboard paste as one contiguous write.
  bool paste(String text) {
    final session = current;
    if (session == null || text.isEmpty) return false;
    // Modifiers are deliberately not consumed: a stuck Ctrl must not rewrite the paste's first byte,
    // and silently swallowing the modifier here would surprise the very next keystroke.
    return session.write(encodePastedText(text));
  }

  void _scrollByPage(ShellSession session, int direction) =>
      session.scrollBy(direction * math.max(1, session.viewportRows - 1));

  @override
  void dispose() {
    _disposed = true;
    _app.removeListener(_onAppChanged);
    unawaited(_actionsSub?.cancel());
    for (final session in _sessions) {
      session.removeListener(_safeNotify);
      session.removeListener(_syncBackgroundSessions);
      session.dispose();
    }
    _sessions.clear();
    // The service outlives this object, so it has to be told. A foreground notification left
    // standing over nothing is exactly the kind of thing users uninstall an app for.
    unawaited(sessionService?.stop());
    super.dispose();
  }
}
