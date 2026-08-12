import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/ssh/dartssh_transport.dart' show SshHostKeyException;
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/remote_commands.dart';
import '../../domain/host_display.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../platform/review_prompt.dart';
import '../../data/term/terminal_emulator.dart';
import '../../data/term/tmux_bootstrap.dart';
import '../../domain/app_preferences.dart';
import '../../domain/server_credentials.dart';
import '../../domain/terminal_key_encoder.dart';
import '../../platform/session_service.dart';
import 'app_state.dart';
import 'shell_session.dart';
import '../../platform/shortcut_helper.dart';

/// The Shell screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Owns the open sessions, which one is focused, the sticky modifier keys, and the one path every
/// keystroke takes to the remote. Splitting input through here rather than through the widgets is
/// what makes the read-only guard and the modifier rules testable without a terminal on screen.
class ShellViewModel extends ChangeNotifier {
  ShellViewModel(
    this._app, {
    this.transport,
    this.sessionService,
    this.reviewPrompt,
    this.hasProbed,
    this.shortcuts,
  }) {
    _useControlMode = _app.preferences.tmuxControlMode;
    _lastPreferenceControlMode = _useControlMode;
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

  /// Counts successful sessions and asks for a store review once, ported from Kotlin's
  /// `noteSuccessfulSshSession`. Nullable: a build with no store SDK simply never prompts.
  final ReviewPromptController? reviewPrompt;

  /// Whether a host's reachability has actually been checked this run.
  ///
  /// Nullable, and a null answer means "not probed" — which suppresses the offline warning rather
  /// than raising it. A build that cannot tell must not invent an alarm.
  final bool Function(int serverId)? hasProbed;

  AppPreferences get preferences => _app.preferences;

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
  bool _terminalVisible = true;

  void setTerminalVisible(bool visible) {
    if (_terminalVisible == visible) return;
    _terminalVisible = visible;
    _syncBackgroundSessions();
  }

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
    final live = [
      for (final session in _sessions)
        if (session.isOpen) BackgroundSession(id: session.id, serverName: session.serverName),
    ];
    // An explicit "Send to background" navigation keeps the session alive even when the general
    // preference is off. Otherwise the preference mirrors Kotlin's TerminalSessionManager: when
    // enabled, protection starts as soon as a session opens, before the lifecycle can race the app
    // into the background.
    final shouldKeepAlive =
        live.isNotEmpty && (!_terminalVisible || preferences.backgroundKeepAlive);
    unawaited(shouldKeepAlive ? sessionService?.sync(live) : sessionService?.stop());
  }

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _onAppChanged() {
    final savedControlMode = preferences.tmuxControlMode;
    // Settings supplies the default for a new connection, while the checkbox remains a genuine
    // per-connection override. Only follow a changed default when the user has not diverged from
    // the previous one in this Shell visit.
    if (_useControlMode == _lastPreferenceControlMode) {
      _useControlMode = savedControlMode;
    }
    _lastPreferenceControlMode = savedControlMode;
    _applyScrollbackLimit();
    _syncBackgroundSessions();
    _safeNotify();
  }

  /// The scrollback limit currently applied to live sessions.
  ///
  /// Tracked so the emulators are only walked when the setting actually changed, rather than on
  /// every unrelated notification from [AppState] — of which there are many.
  int? _appliedScrollbackLimit;

  /// Pushes a changed scrollback limit into every running session.
  ///
  /// Ported from `saveTerminalScrollbackLimit` (`ui/AppViewModel.kt:1900`). Flutter read the setting
  /// only when *building* a session, so lowering the limit to reclaim memory did nothing to the
  /// sessions already holding it — the user had to reconnect to get the effect they had asked for,
  /// which is the opposite of what someone reaching for that setting wants.
  void _applyScrollbackLimit() {
    final limit = preferences.terminalScrollbackLimit;
    if (limit == _appliedScrollbackLimit) return;
    _appliedScrollbackLimit = limit;
    for (final session in _sessions) {
      session.emulator.setScrollbackLimit(limit);
    }
  }

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
    _offerSplitShortcut();
    _safeNotify();
  }

  /// Launcher shortcuts. Null in tests and on platforms without them; the split shortcut is then
  /// simply not offered, which is what [ShortcutHelper] does for every other action too.
  final ShortcutHelper? shortcuts;

  /// Offers the current pair as a launcher shortcut.
  ///
  /// Kotlin pushes one whenever two hosts are loaded into panes
  /// (`AppViewModel.kt:1712`). Flutter had `ShortcutHelper.pushSplit` and a complete native
  /// implementation behind it — and no caller, so the shortcut could never appear.
  ///
  /// Best-effort by construction: `pushSplit` swallows MissingPlugin and PlatformException and
  /// answers false, because failing to offer a shortcut must never interrupt opening a terminal.
  void _offerSplitShortcut() {
    final helper = shortcuts;
    if (helper == null) return;
    final first = current;
    final second = splitSession;
    if (first == null || second == null) return;
    final firstServer = _app.servers.where((server) => server.id == first.serverId).firstOrNull;
    final secondServer = _app.servers.where((server) => server.id == second.serverId).firstOrNull;
    if (firstServer == null || secondServer == null) return;
    unawaited(helper.pushSplit(firstServer, secondServer));
  }

  /// True when a host could be connected into a second pane.
  ///
  /// Distinct from [splitCandidates], which lists sessions that are already running: this is what
  /// makes the split control worth showing when only one terminal is open.
  bool get canConnectSecondPane {
    final open = _sessions.map((session) => session.serverId).toSet();
    return connectableServers.any((server) => !open.contains(server.id));
  }

  /// Connects [server] and shows it in the second pane.
  ///
  /// Kotlin can load two *hosts* into panes in one action (`ui/AppUi.kt:196–235`, gated by
  /// `allowSplitSelection`). The port could only split sessions that were **already connected**, so
  /// putting a second host alongside meant connecting it, having it take over the screen, and then
  /// splitting back — three steps for what Kotlin does in one, and the split picker said so:
  /// "Open a second session first".
  ///
  /// The current pane is deliberately restored afterwards. `connect` focuses what it opens, which
  /// is right when connecting normally and wrong here: the user asked for this host *alongside* the
  /// one they are looking at, not instead of it.
  ///
  /// A failed or cancelled connection leaves the split untouched. `connect` has already reported
  /// why on screen, and forcing a split with nothing in it would replace that explanation with an
  /// empty pane.
  Future<void> splitWithNewSession(Server server) async {
    final keepCurrent = _currentId;
    final before = _sessions.map((session) => session.id).toSet();
    await connect(server);
    final opened = _sessions.where((session) => !before.contains(session.id)).firstOrNull;
    if (opened == null) return;
    if (keepCurrent != null && _sessions.any((session) => session.id == keepCurrent)) {
      _currentId = keepCurrent;
    }
    splitWith(opened.id);
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
  int _connectGeneration = 0;
  bool get isConnecting => _connecting;

  void cancelConnect() {
    if (!_connecting) return;
    _connectGeneration++;
    _connecting = false;
    _phase = null;
    _safeNotify();
  }

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
  bool _lastPreferenceControlMode = false;

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
  // ── offline confirmation ────────────────────────────────────────────────────
  //
  // Ported from the gate in `connectTerminal` and `OfflineConnectDialog` (`ui/AppViewModel.kt:4496`,
  // `ui/AppUi.kt:671`). It lives here rather than on a screen because a host is connected from the
  // host list, the Infra tab's container shell, a quick-connect sheet, a shortcut and a quick
  // action — a gate on one of those covers one of those.

  /// The host waiting on an "connect anyway?" decision, or null.
  Server? get offlineConnectPromptServer => _offlineConnectPromptServer;
  Server? _offlineConnectPromptServer;

  void dismissOfflineConnectPrompt() {
    if (_offlineConnectPromptServer == null) return;
    _offlineConnectPromptServer = null;
    _safeNotify();
  }

  /// Re-enters [connect] with the offline gate bypassed.
  Future<void> connectConfirmedOffline() async {
    final server = _offlineConnectPromptServer;
    if (server == null) return;
    _offlineConnectPromptServer = null;
    _safeNotify();
    await connect(server, confirmedOffline: true);
  }

  // ── tmux availability ───────────────────────────────────────────────────────
  //
  // Ported from `TmuxInstallDialog` and `installTmuxAndConnect` (`ui/AppUi.kt:617`,
  // `ui/AppViewModel.kt:5911`).

  /// The host waiting on a tmux decision, or null.
  Server? get tmuxPromptServer => _tmuxPromptServer;
  Server? _tmuxPromptServer;

  /// Streamed installer output while it runs, or null when nothing has been attempted.
  String? get tmuxInstallOutput => _tmuxInstallOutput;
  String? _tmuxInstallOutput;

  bool get tmuxInstalling => _tmuxInstalling;
  bool _tmuxInstalling = false;

  /// Hosts already confirmed to have tmux, so the probe runs once per host per session rather than
  /// before every connection.
  final Set<int> _tmuxVerified = <int>{};

  void dismissTmuxPrompt() {
    if (_tmuxPromptServer == null) return;
    _tmuxPromptServer = null;
    _tmuxInstallOutput = null;
    _safeNotify();
  }

  /// Connects anyway, accepting an ordinary non-resumable shell.
  Future<void> connectWithoutPersistence() async {
    final server = _tmuxPromptServer;
    if (server == null) return;
    dismissTmuxPrompt();
    await connect(server, forcePlainShell: true);
  }

  /// Installs tmux on the prompted host, then connects with persistence.
  Future<void> installTmuxAndConnect() async {
    final server = _tmuxPromptServer;
    final ssh = transport;
    if (server == null || ssh == null || _tmuxInstalling) return;
    _tmuxInstalling = true;
    _tmuxInstallOutput = '';
    _safeNotify();

    var installed = false;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      await ssh.execStream(
        creds,
        tmuxInstallCommand(),
        stdin: sudoStdin(server.sudoPassword),
        onChunk: (chunk) async {
          if (_disposed) return;
          _tmuxInstallOutput = (_tmuxInstallOutput ?? '') + chunk;
          _safeNotify();
        },
      );
      // Re-probed rather than trusting the installer's exit code, for the same reason the script
      // re-checks itself: a package manager can report success against a broken mirror.
      installed = await _hasTmux(server);
    } catch (e) {
      _tmuxInstallOutput = '${_tmuxInstallOutput ?? ''}\n\n$e';
    }
    if (_disposed) return;
    _tmuxInstalling = false;

    if (!installed) {
      _tmuxInstallOutput =
          '${_tmuxInstallOutput ?? ''}\n\nInstall did not complete. You can retry, '
          'connect non-resumable, or install tmux manually.';
      _safeNotify();
      return;
    }
    _tmuxVerified.add(server.id);
    dismissTmuxPrompt();
    await connect(server);
  }

  Future<bool> _hasTmux(Server server) async {
    final ssh = transport;
    if (ssh == null) return false;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final answer = await ssh.exec(creds, tmuxCheckCommand);
      return answer.trim().endsWith('yes');
    } catch (_) {
      // A probe that could not run is not evidence tmux is missing, and refusing to connect over it
      // would be worse than the silent degradation this replaces. Treat it as present and let the
      // self-guarding bootstrap command decide.
      return true;
    }
  }

  Future<void> connect(
    Server server, {
    String? resumeName,
    bool controlMode = false,
    String? initialCommand,
    bool forcePlainShell = false,
    bool confirmedOffline = false,
  }) async {
    if (_connecting) return;

    // Checked before the tmux probe, which costs a round trip: there is no point asking a host
    // whether it has tmux when the last check said it was not answering at all.
    if (!confirmedOffline &&
        shouldWarnHostOffline(probed: hasProbed?.call(server.id) ?? false, status: server.status)) {
      _offlineConnectPromptServer = server;
      _safeNotify();
      return;
    }
    final ssh = transport;
    if (ssh == null) {
      _error = 'The terminal is unavailable in this build: no SSH transport is wired.';
      _safeNotify();
      return;
    }

    // A host configured for persistent sessions but missing tmux used to connect as an ordinary
    // shell with no notice: the user believed their work survived a dropped link, and it did not.
    // Probed once per host per session; the answer is only acted on when it is a definite "no".
    if (server.persistentSession && !forcePlainShell && !_tmuxVerified.contains(server.id)) {
      if (await _hasTmux(server)) {
        _tmuxVerified.add(server.id);
      } else {
        _tmuxPromptServer = server;
        _tmuxInstallOutput = null;
        _safeNotify();
        return;
      }
    }

    _connecting = true;
    final generation = ++_connectGeneration;
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
          if (_disposed || generation != _connectGeneration) return;
          _phase = phase;
          _safeNotify();
        },
      );
      if (_disposed || generation != _connectGeneration) {
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
      final persistent = server.persistentSession && !forcePlainShell
          ? await _persistentTarget(server, resumeName: resumeName, controlMode: controlMode)
          : null;
      if (_disposed || generation != _connectGeneration) {
        channel.close();
        return;
      }

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
      // Fire-and-forget: the parser must not block on an SSH round trip, and until the query comes
      // back the old pane id keeps working, which is the pre-existing behaviour rather than a
      // regression.
      session.onPaneChanged = (changed) => unawaited(refreshControlActivePane(changed));
      session.addListener(_safeNotify);
      session.addListener(_syncBackgroundSessions);
      _sessions.add(session);
      _currentId = session.id;

      // A session that reached this point authenticated and opened a channel, which is the only
      // definition of "it worked" worth counting. Fire-and-forget: the terminal must not wait on a
      // settings write, and a failed nudge is never the user's problem.
      unawaited(reviewPrompt?.noteSuccessfulSession() ?? Future<void>.value());

      // A host marked "persistent" is put inside tmux immediately, which is the whole point: a
      // dropped link then leaves the work running on the server instead of killing it. Written as
      // the shell's first input rather than run as a channel command, so a host without tmux is
      // left at a perfectly ordinary prompt (the command guards itself with `command -v tmux`).
      if (persistent != null) {
        session.write(Uint8List.fromList(utf8.encode(persistent.$2)));
        await _reloadSaved();
      }
      if (initialCommand != null && initialCommand.trim().isNotEmpty) {
        session.write(Uint8List.fromList(utf8.encode('${initialCommand.trim()}\r')));
      }
      _syncBackgroundSessions();
    } on CredentialResolutionException catch (e) {
      if (generation == _connectGeneration) _error = e.message;
    } on SshHostKeyException catch (e) {
      // Named separately from an auth failure because the fix is different and the stakes are
      // different: "wrong password" is a nuisance, "this host's key changed" is either a rebuilt
      // server or someone standing between you and it, and the app must not blur the two.
      if (generation == _connectGeneration) {
        _error = switch (e.verdict) {
          HostKeyVerdict.changed =>
            'The host key for ${server.name} has CHANGED. This is what a machine-in-the-middle looks '
                'like. If you rebuilt or replaced this server, remove its pinned key under '
                'Tools › Auth & keys and connect again — otherwise do not.',
          _ =>
            'The host key for ${server.name} was not accepted, so the connection was refused. '
                'Connect again to see the fingerprint prompt.',
        };
      }
    } on SshConnectException catch (e) {
      if (generation == _connectGeneration) _error = e.message;
    } catch (e) {
      if (generation == _connectGeneration) {
        _error = 'Could not open a shell on ${server.name}: $e';
      }
    } finally {
      if (generation == _connectGeneration) {
        _connecting = false;
        _phase = null;
        _safeNotify();
      }
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
    if (_currentId == session.id) {
      _currentId = _sessions.isEmpty ? null : _sessions.last.id;
    }
    session.dispose();
    _syncBackgroundSessions();
    _safeNotify();
  }

  /// Terminates a persistent tmux session on the host, then closes its local SSH channel.
  Future<void> terminate(ShellSession session) async {
    final tmuxName = session.tmuxName;
    if (tmuxName == null) {
      close(session);
      return;
    }
    final server = _app.servers.where((server) => server.id == session.serverId).firstOrNull;
    try {
      if (server == null || transport == null) {
        throw StateError('The host or SSH transport is no longer available.');
      }
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      await transport!.exec(creds, tmuxKillCommand(tmuxName));
      await _app.repository.deletePersistentSession(tmuxName);
    } catch (e) {
      _error =
          'Disconnected locally, but the remote tmux session could not be confirmed stopped. '
          'It remains available for recovery: $e';
    }
    close(session);
  }

  Future<void> disconnectAll({bool terminatePersistent = true}) async {
    cancelConnect();
    for (final session in _sessions.toList()) {
      if (terminatePersistent && session.tmuxName != null) {
        await terminate(session);
      } else {
        close(session);
      }
    }
  }

  /// Detaches persistent sessions so tmux can be resumed; ordinary sessions stay connected.
  void leaveOrBackgroundAll() {
    for (final session in _sessions.toList()) {
      if (session.tmuxName != null) close(session);
    }
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

  /// Adopts the modifiers held on a **hardware** keyboard for the next send.
  ///
  /// Kotlin does the same assignment before every physical key (`ui/ShellScreen.kt:2322`), which is
  /// what makes Ctrl+C and Alt+Left work on an attached keyboard: `sendKey` and `typeText` read
  /// these fields and clear them afterwards, so the modifier applies to exactly one keystroke and
  /// then goes, exactly as a real Ctrl does.
  ///
  /// Sticky on-screen modifiers use the same fields deliberately. A user holding Ctrl on a keyboard
  /// while a sticky Ctrl is latched means Ctrl either way, and OR-ing them keeps the latched one
  /// from being dropped by an unmodified hardware key.
  void applyHardwareModifiers({required bool shift, required bool alt, required bool ctrl}) {
    final next = (this.shift || shift, this.alt || alt, this.ctrl || ctrl);
    if ((this.shift, this.alt, this.ctrl) == next) return;
    this.shift = next.$1;
    this.alt = next.$2;
    this.ctrl = next.$3;
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

  /// Whether a capture is already in flight, so two scroll gestures cannot race one.
  bool _resyncing = false;

  /// Re-reads a persistent session's scrollback from the pane's own tmux history.
  ///
  /// Sessions whose active pane is being resolved right now, so a burst of notifications produces
  /// one query rather than one per notification.
  final _paneRefreshing = <ShellSession>{};

  /// Re-resolve the pane keystrokes are addressed to, after tmux said it may have moved.
  ///
  /// Ported from `refreshControlActivePane` (`ui/AppViewModel.kt:5139`). Control mode addresses
  /// input explicitly (`send-keys -t <pane>`), and the pane is learned from the first `%output` the
  /// session ever sees. Switch window inside tmux and that id goes stale: tmux streams the new
  /// pane's output while OmniTerm keeps typing into the old one — keystrokes land somewhere the user
  /// is not looking.
  ///
  /// The obvious shortcut — track the *latest* `%output` pane — is wrong, and is why this needs a
  /// query at all: a background pane producing output would steal the keyboard, which is the same
  /// defect pointed the other way.
  Future<bool> refreshControlActivePane(ShellSession session) async {
    final name = session.tmuxName;
    final ssh = transport;
    if (name == null || ssh == null || !session.controlMode) return false;
    if (!_paneRefreshing.add(session)) return false;
    final host = _app.servers.where((s) => s.id == session.serverId).firstOrNull;
    if (host == null) {
      _paneRefreshing.remove(session);
      return false;
    }

    try {
      final creds = resolveCredentials(
        host,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      // Retry rather than return: a switch that lands while the query is in flight would otherwise
      // be answered with the pane the user has just left.
      while (true) {
        final revision = session.paneChangeRevision;
        final buffer = StringBuffer();
        await ssh.execStream(
          creds,
          tmuxActivePaneQuery(name),
          onChunk: (chunk) async => buffer.write(chunk),
        );
        final paneId = buffer.toString().trim();
        // `%0`, not "whatever came back": the command ends in `|| true`, so a tmux that has gone
        // away answers with an empty string, and adopting that would address input to nothing.
        if (!RegExp(r'^%\d+$').hasMatch(paneId)) return false;
        if (session.paneChangeRevision != revision) continue;
        if (session.adoptControlPane(paneId, revision)) return true;
        if (session.paneChangeRevision == revision) return false;
      }
    } catch (_) {
      // Leave `paneChangePending` set: the pane is still unresolved, and the next notification or
      // reconnect retries. Failing loudly here would take down a session whose only problem is that
      // one side-channel exec did not come back.
      return false;
    } finally {
      _paneRefreshing.remove(session);
    }
  }

  /// Ported from `resyncTmuxScrollbackFor` (`ui/AppViewModel.kt:4967`). tmux does not stream every
  /// line to an attached client — output faster than the client consumes is collapsed into a
  /// repaint — so a burst leaves the local scrollback missing rows the pane still holds. They are
  /// not recoverable locally: the pane's history lives on the server, and this fetches it, re-parses
  /// it at the live grid's width and swaps it in wholesale.
  ///
  /// Returns the change in row count so the caller can keep the viewport steady. Zero when nothing
  /// was adopted, which is the normal answer: not persistent, not dirty, already running, no
  /// transport, or a capture that came back empty because a TUI owns the pane.
  Future<int> resyncTmuxScrollback(ShellSession session) async {
    final name = session.tmuxName;
    final ssh = transport;
    if (name == null || ssh == null || !session.scrollbackDirty || _resyncing) return 0;
    final host = _app.servers.where((s) => s.id == session.serverId).firstOrNull;
    if (host == null) return 0;

    _resyncing = true;
    // Cleared *before* the capture, not after: output arriving mid-capture re-arms it, so the next
    // scroll retries rather than trusting a capture that missed those rows. Kotlin says the same at
    // `ui/AppViewModel.kt:4987`.
    session.scrollbackDirty = false;
    final cols = session.cols;
    final rows = session.rows;
    try {
      final creds = resolveCredentials(
        host,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final limit = preferences.terminalScrollbackLimit;
      // A byte budget rather than an unbounded buffer: a pane with 50,000 rows of output is a
      // multi-megabyte string, and only the tail of it can survive the scrollback limit anyway.
      final budget = limit * 300 + 65536;
      final buffer = StringBuffer();
      await ssh.execStream(
        creds,
        tmuxCaptureHistoryCommand(name, limit),
        onChunk: (chunk) async {
          buffer.write(chunk);
          if (buffer.length > budget) {
            final kept = buffer.toString();
            buffer
              ..clear()
              ..write(kept.substring(kept.length - budget));
          }
        },
      );
      final history = buffer.toString().trimRight();
      // Empty is the `#{alternate_on}` guard firing: a TUI owns the pane and `capture-pane` would
      // return its frames rather than history. Re-arm and let a later scroll try again.
      if (history.isEmpty || history.startsWith('SSH Error:')) {
        session.scrollbackDirty = true;
        return 0;
      }

      // The capture is only valid for the grid it was taken against. A resize in flight means the
      // rows would be re-wrapped to the wrong width, so it is discarded rather than adopted.
      if (session.cols != cols || session.rows != rows) {
        session.scrollbackDirty = true;
        return 0;
      }

      final scratch = TerminalEmulator(cols: cols, rows: rows, scrollbackLimit: limit);
      scratch.feed(Uint8List.fromList(utf8.encode(history.replaceAll('\n', '\r\n'))));
      // A screen-height of newlines pushes the tail off the scratch screen, so everything the
      // capture contained ends up in its *scrollback* — which is the half being adopted.
      scratch.feed(Uint8List.fromList(utf8.encode('\r\n' * rows)));
      return session.adoptScrollback(scratch);
    } catch (_) {
      // A capture that could not run is not evidence the history is gone. Leave it armed.
      session.scrollbackDirty = true;
      return 0;
    } finally {
      _resyncing = false;
    }
  }

  /// Send a clipboard paste as one contiguous write.
  bool paste(String text) {
    final session = current;
    if (session == null || text.isEmpty) return false;
    // Modifiers are deliberately not consumed: a stuck Ctrl must not rewrite the paste's first byte,
    // and silently swallowing the modifier here would surprise the very next keystroke.
    //
    // The remote's DECSET 2004 state is read now rather than cached: a shell turns bracketed paste
    // on and off around its own prompt, so the only moment the answer is true is this one.
    return session.write(encodePastedText(text, bracketed: session.emulator.bracketedPasteMode));
  }

  /// Mirrors an editor-style swipe/autocorrect edit as one ordered terminal write.
  bool applyLineEdit({required int backspaces, required String insert}) {
    final session = current;
    if (session == null || session.readOnly || (backspaces <= 0 && insert.isEmpty)) {
      return false;
    }
    return session.write(
      Uint8List.fromList([...List.filled(backspaces, 0x7f), ...utf8.encode(insert)]),
    );
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
