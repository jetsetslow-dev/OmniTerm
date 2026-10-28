import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/ssh/dartssh_transport.dart' show SshHostKeyException;
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/remote_commands.dart';
import '../../domain/host_display.dart';
import '../../domain/quick_connect.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../platform/review_prompt.dart';
import '../../data/term/terminal_emulator.dart';
import '../../data/term/tmux_bootstrap.dart';
import '../../domain/app_preferences.dart';
import '../../domain/server_credentials.dart';
import '../../domain/ssh_failure.dart';
import '../../domain/terminal_key_encoder.dart';
import '../../platform/session_service.dart';
import 'app_state.dart';
import 'shell_session.dart';
import '../../platform/shortcut_helper.dart';

class _LeaveSuperseded implements Exception {}

/// The requested destination survives offline/tmux decisions and asynchronous SSH setup.
class _ShellConnectRequest {
  const _ShellConnectRequest({
    required this.server,
    this.resumeName,
    this.controlMode = false,
    this.initialCommand,
    this.forcePlainShell = false,
    this.confirmedOffline = false,
    this.freshSession = false,
    this.pane,
    this.paneRevision,
  });
  final Server server;
  final String? resumeName;
  final bool controlMode;
  final String? initialCommand;
  final bool forcePlainShell;
  final bool confirmedOffline;
  final bool freshSession;
  final int? pane;
  final int? paneRevision;

  _ShellConnectRequest continueWith({bool? forcePlainShell, bool? confirmedOffline}) =>
      _ShellConnectRequest(
        server: server,
        resumeName: resumeName,
        controlMode: controlMode,
        initialCommand: initialCommand,
        forcePlainShell: forcePlainShell ?? this.forcePlainShell,
        confirmedOffline: confirmedOffline ?? this.confirmedOffline,
        freshSession: freshSession,
        pane: pane,
        paneRevision: paneRevision,
      );
}

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
    this.markReachable,
    this.syncLiveSessionServers,
    this.recheckHost,
    this.shortcuts,
    this.hostKeyTrust,
  }) {
    _smartSwipeInput = _app.preferences.smartSwipeInput;
    _lastPreferenceSmartSwipe = _smartSwipeInput;
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

  /// Records the result of the most authoritative reachability check: a real interactive shell.
  final Future<void> Function(Server server)? markReachable;

  /// Publishes the hosts with open interactive channels so an advisory background probe cannot
  /// contradict a terminal that is demonstrably connected.
  final void Function(Set<int> serverIds)? syncLiveSessionServers;
  final Future<void> Function(Server server)? recheckHost;

  AppPreferences get preferences => _app.preferences;

  late bool _smartSwipeInput;
  late bool _lastPreferenceSmartSwipe;
  bool get smartSwipeInput => _smartSwipeInput;

  /// A runtime override; Settings continues to supply the saved default.
  void setSmartSwipeRuntime(bool enabled) {
    if (_disposed || _smartSwipeInput == enabled) return;
    _smartSwipeInput = enabled;
    _safeNotify();
  }

  /// Null in tests and in any build without a transport wired. Connecting then reports that the
  /// terminal is unavailable rather than opening a screen that will never receive a byte
  /// (Convention 4).
  final SshTransport? transport;

  final _sessionCredentials = <ShellSession, SshCredentials>{};
  final _sessionHosts = <ShellSession, Server>{};
  final _paneAltCache = <ShellSession, ({bool active, int checkedAtMs})>{};
  final _reconnectRuns = <ShellSession, _ReconnectRun>{};

  void _onSessionChanged() {
    for (final session in _sessions.toList()) {
      if (session.endReason == ShellSessionEnd.disconnected &&
          !session.reconnecting &&
          session.reconnectError == null) {
        retrySession(session);
      }
    }
    _safeNotify();
  }

  /// A genuine socket loss reconnects in place. Navigation never enters this path.
  void retrySession(ShellSession session) {
    if (_disposed ||
        !_sessions.contains(session) ||
        session.isOpen ||
        session.endReason != ShellSessionEnd.disconnected ||
        _reconnectRuns.containsKey(session)) {
      return;
    }
    if (transport == null || !_sessionCredentials.containsKey(session)) return;
    final run = _ReconnectRun();
    _reconnectRuns[session] = run;
    session.reconnecting = true;
    session.reconnectError = null;
    session.publishNow();
    _scheduleReconnect(session, run);
  }

  bool _ownsReconnect(ShellSession session, _ReconnectRun run) =>
      !_disposed && identical(_reconnectRuns[session], run) && _sessions.contains(session);

  void _scheduleReconnect(ShellSession session, _ReconnectRun run) {
    final seconds = math.min(1 << math.min(run.attempt, 5), 30);
    run.timer = Timer(Duration(seconds: seconds), () => unawaited(_reconnect(session, run)));
  }

  Future<void> _reconnect(ShellSession session, _ReconnectRun run) async {
    if (!_ownsReconnect(session, run)) return;
    run.attempt++;
    TerminalSession? replacement;
    var adopted = false;
    try {
      final creds = _sessionCredentials[session]!;
      final ssh = transport!;
      final name = session.tmuxName;
      if (name != null) {
        final presence = parseTmuxSessionProbe(
          await ssh.exec(creds, tmuxSessionProbeCommand(name)),
        );
        if (!_ownsReconnect(session, run)) return;
        if (presence == null) {
          throw SshConnectException('Could not verify the saved tmux session.');
        }
        if (!presence) {
          await _app.repository.deletePersistentSession(session.serverId, name);
          if (!_ownsReconnect(session, run)) return;
          await _reloadSaved();
          if (!_ownsReconnect(session, run)) return;
          _finishReconnect(
            session,
            run,
            'Tmux confirmed that this session no longer exists. No empty replacement was created.',
          );
          return;
        }
      }
      replacement = await ssh.openShell(creds, session.cols, session.rows);
      if (!_ownsReconnect(session, run)) return;
      if (name != null) {
        await replacement.write(
          Uint8List.fromList(
            utf8.encode(
              tmuxResumeCommand(
                name,
                historyLimit: preferences.terminalScrollbackLimit,
                controlMode: session.controlMode,
              ),
            ),
          ),
        );
      }
      if (!_ownsReconnect(session, run)) return;
      if (replacement.closed.value) {
        throw SshConnectException('SSH channel closed during reconnect.');
      }
      _reconnectRuns.remove(session);
      adopted = session.reconnectWith(replacement);
      if (!adopted) return;
      final server = _app.servers.where((s) => s.id == session.serverId).firstOrNull;
      if (server != null) unawaited(markReachable?.call(server) ?? Future<void>.value());
      _syncReachabilityEvidence();
      _syncBackgroundSessions();
    } catch (error) {
      if (!_ownsReconnect(session, run)) return;
      if (run.attempt >= 12) {
        _finishReconnect(
          session,
          run,
          'Connection lost — reconnect failed. ${describeSshFailure('$error')}',
        );
      } else {
        _scheduleReconnect(session, run);
      }
    } finally {
      if (!adopted) {
        try {
          replacement?.close();
        } catch (_) {
          // A replacement can die before adoption too. Cleanup must not escape the retry loop.
        }
      }
    }
  }

  void _finishReconnect(ShellSession session, _ReconnectRun run, String message) {
    if (!_ownsReconnect(session, run)) return;
    _reconnectRuns.remove(session);
    session.reconnecting = false;
    session.reconnectError = message;
    session.publishNow();
    _syncBackgroundSessions();
  }

  bool get canConnect => transport != null;

  /// Keeps the process alive while sessions are open in the background. Null in tests and on
  /// platforms without one — sessions then simply do not survive the app being backgrounded, which
  /// is the platform's behaviour rather than something the app can pretend away.
  final SessionService? sessionService;

  StreamSubscription<SessionServiceAction>? _actionsSub;
  bool _terminalVisible = true;
  List<BackgroundSession>? _lastBackgroundSessions;
  Future<void>? _backgroundSyncWork;

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
        resumeExisting(sessionId);
    }
  }

  /// Tell the platform which sessions are open.
  ///
  /// Called after every change to the list rather than only on backgrounding: the notification is
  /// the user's view of what this app is holding open, and one that lags reality is worse than none.
  Future<void> _syncBackgroundSessions() {
    final live = [
      for (final session in _sessions)
        if (session.isOpen || session.reconnecting)
          BackgroundSession(id: session.id, serverName: session.serverName),
    ];
    // An explicit "Send to background" navigation keeps the session alive even when the general
    // preference is off. Otherwise the preference mirrors Kotlin's TerminalSessionManager: when
    // enabled, protection starts as soon as a session opens, before the lifecycle can race the app
    // into the background.
    final shouldKeepAlive =
        live.isNotEmpty &&
        (!_terminalVisible ||
            preferences.backgroundKeepAlive ||
            live.any((s) => _backgroundedAt.containsKey(s.id)));
    final desired = shouldKeepAlive ? live : const <BackgroundSession>[];
    // Terminal repaint notifications are not service-state changes. Sending a foreground start
    // for every output frame floods Android and races rapid background/foreground transitions.
    if (listEquals(_lastBackgroundSessions, desired)) {
      return _backgroundSyncWork ?? Future<void>.value();
    }
    _lastBackgroundSessions = desired;
    final operation = shouldKeepAlive ? sessionService?.sync(live) : sessionService?.stop();
    if (operation != null) {
      late final Future<void> work;
      work = operation
          .then((result) {
            // Clearing the cache is what lets the next change retry; it is not, on its own, telling
            // anyone. A keep-alive that Android refused used to end here in silence, leaving the user
            // to believe their shells were protected in the background when they were not.
            if (result.failed && identical(_lastBackgroundSessions, desired)) {
              _lastBackgroundSessions = null;
            }
            _reportBackgroundServiceResult(result, keepAlive: shouldKeepAlive);
          })
          .whenComplete(() {
            if (identical(_backgroundSyncWork, work)) _backgroundSyncWork = null;
          });
      _backgroundSyncWork = work;
      return work;
    }
    return Future<void>.value();
  }

  /// The last background-service failure the user has not dismissed, or null.
  ///
  /// Only a genuine refusal on a platform that supports the service appears here.
  /// [SessionServiceOutcome.unsupported] is iOS behaving as designed and there is nothing the user
  /// could do about it, so it must never be dressed up as an error.
  String? get backgroundServiceWarning => _backgroundServiceWarning;
  String? _backgroundServiceWarning;

  /// Remembered so dismissing means something. A failure clears the cache above so the next change
  /// retries, that retry fails the same way, and without this the warning reappeared immediately.
  String? _dismissedBackgroundServiceWarning;

  void dismissBackgroundServiceWarning() {
    if (_backgroundServiceWarning == null) return;
    _dismissedBackgroundServiceWarning = _backgroundServiceWarning;
    _backgroundServiceWarning = null;
    _safeNotify();
  }

  void _reportBackgroundServiceResult(SessionServiceResult result, {required bool keepAlive}) {
    if (_disposed) return;
    final message = switch (result.outcome) {
      SessionServiceOutcome.ok || SessionServiceOutcome.unsupported => null,
      SessionServiceOutcome.failed when keepAlive =>
        'Sessions may not survive the app being in the background: '
            '${result.detail ?? 'the device refused to start the background service'}.',
      // A failed stop is the opposite problem and just as worth saying: a notification can be left
      // standing over sessions that are gone.
      SessionServiceOutcome.failed =>
        'The background session notification may still be showing: '
            '${result.detail ?? 'the device refused to stop the background service'}.',
    };
    if (message == null) {
      // It worked, or there is nothing to do here. Forget the warning *and* the dismissal, so a
      // later failure is heard again rather than being silenced by an old one.
      _dismissedBackgroundServiceWarning = null;
      if (_backgroundServiceWarning == null) return;
      _backgroundServiceWarning = null;
      _safeNotify();
      return;
    }
    // Every open session notifies on output, so this runs constantly. Re-announcing an unchanged
    // state would bury the terminal under its own warning — and re-raising one the user has
    // already dismissed would make the dismiss button a no-op.
    if (message == _backgroundServiceWarning || message == _dismissedBackgroundServiceWarning) {
      return;
    }
    _backgroundServiceWarning = message;
    _safeNotify();
  }

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _onAppChanged() {
    final savedSwipe = preferences.smartSwipeInput;
    if (savedSwipe != _lastPreferenceSmartSwipe) {
      _lastPreferenceSmartSwipe = savedSwipe;
      _smartSwipeInput = savedSwipe;
    }
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
  List<Server> get connectableServers => _app.onlineServers;

  /// The host the screen is showing.
  ///
  /// The focused session's host wins, because the header must name exactly the terminal on screen.
  /// Falling back to the selected host while a session is open made the header actively misleading.
  Server? get server {
    final session = current;
    if (session != null) {
      final owner = _app.servers.where((s) => s.id == session.serverId).firstOrNull;
      if (owner != null) return owner;
      final temporary = _sessionHosts[session];
      if (temporary != null) return temporary;
    }
    final online = connectableServers;
    return online.where((s) => s.id == _app.selectedServerId).firstOrNull ??
        (online.isNotEmpty ? online.first : _failedConnectTarget);
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
  Set<int> _lastLiveSessionServers = <int>{};

  void _syncReachabilityEvidence() {
    final live = _sessions
        .where((session) => session.isOpen)
        .map((session) => session.serverId)
        .toSet();
    if (setEquals(live, _lastLiveSessionServers)) return;
    _lastLiveSessionServers = live;
    syncLiveSessionServers?.call(Set.unmodifiable(live));
  }

  String? _currentId;
  bool _showConnectPrompt = false;
  final Map<String, int> _backgroundedAt = {};
  int? backgroundedAtFor(String id) => _backgroundedAt[id];
  bool _isBackgroundingSession = false;
  bool get isBackgroundingSession => _isBackgroundingSession;
  bool _terminalReadOnly = false;
  bool get terminalReadOnly => _terminalReadOnly;

  /// Kotlin's runtime display mode protects every pane, including sessions opened afterward.
  void setTerminalReadOnly(bool enabled) {
    if (_disposed) return;
    if (enabled) _resetPendingSmartInput();
    _terminalReadOnly = enabled;
    if (enabled) _clearModifiers();
    for (final session in _sessions) {
      session.setReadOnly(enabled);
    }
    _safeNotify();
  }

  ShellSession? get current => isSplit
      ? (focusedPane == 1 ? splitFirstSession : splitSecondSession)
      : _showConnectPrompt
      ? null
      : _sessions.where((s) => s.id == _currentId).firstOrNull ??
            (_sessions.isNotEmpty ? _sessions.last : null);

  void select(String id) {
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return;
    _selectWithoutValidation(session);
    if (session.tmuxName != null) unawaited(_validateExistingTmux(session));
  }

  void _selectWithoutValidation(ShellSession session) {
    if (isSplit) {
      if (session.id == _splitFirstId) {
        focusSplitPane(1);
      } else if (session.id == _splitId) {
        focusSplitPane(2);
      } else {
        assignSplitPane(focusedPane, session.id);
      }
      return;
    }
    _showConnectPrompt = false;
    _backgroundedAt.remove(session.id);
    _currentId = session.id;
    _safeNotify();
    unawaited(_syncBackgroundSessions());
  }

  /// Detach tmux or keep plain SSH alive while returning to the connection prompt.
  Future<bool> backgroundSession(ShellSession session) async {
    if (_disposed ||
        _isBackgroundingSession ||
        _isLeavingSessions ||
        !_sessions.contains(session)) {
      return false;
    }
    final split = isSplit;
    _isBackgroundingSession = true;
    _safeNotify();
    try {
      if (session.tmuxName != null) {
        if (!await leaveResumable(session)) return false;
      } else {
        _backgroundedAt[session.id] = DateTime.now().millisecondsSinceEpoch;
      }
      if (split && isSplit) {
        _clearSplitSession(session.id);
      } else {
        _currentId = null;
        _showConnectPrompt = true;
      }
      await _syncBackgroundSessions();
      return true;
    } catch (error) {
      _error = 'Could not send this session to background: $error';
      return false;
    } finally {
      _isBackgroundingSession = false;
      _safeNotify();
    }
  }

  Future<void> switchTerminalHost(Server server) async {
    final previous = current;
    if (previous != null && previous.serverId != server.id) {
      if (!await backgroundSession(previous)) return;
    }
    _app.selectedServerId = server.id;
    final otherId = !isSplit
        ? null
        : focusedPane == 1
        ? _splitId
        : _splitFirstId;
    final existing = _sessions
        .where((s) => s.serverId == server.id && s.isOpen && s.id != otherId)
        .firstOrNull;
    if (existing != null) {
      resumeExisting(existing.id);
    } else {
      await connect(server, controlMode: useControlMode, freshSession: isSplit);
    }
  }

  int _terminalResumeRevision = 0;
  int get terminalResumeRevision => _terminalResumeRevision;

  /// An explicit notification/shortcut resume supersedes a pending leave, even when this tab
  /// was already selected. Ordinary tab selection is not an external navigation decision.
  bool resumeExisting(String id) {
    if (!_sessions.any((session) => session.id == id)) return false;
    _terminalResumeRevision++;
    select(id);
    return true;
  }

  Future<void> _validateExistingTmux(ShellSession session) async {
    if (_connecting || _pendingConnectRequest != null || _tmuxInstalling || _disposed) return;
    _connecting = true;
    _validationPane = !isSplit
        ? null
        : session.id == _splitFirstId
        ? 1
        : session.id == _splitId
        ? 2
        : null;
    _phase = 'Checking tmux session…';
    _error = null;
    _failedConnectTarget = null;
    final generation = ++_connectGeneration;
    _safeNotify();
    final server = _app.servers.where((s) => s.id == session.serverId).firstOrNull;
    final connectionRevision = session.connectionRevision;
    try {
      final ssh = transport;
      final creds = _sessionCredentials[session];
      if (ssh == null || creds == null || server == null) {
        throw SshConnectException('The saved host or SSH transport is unavailable.');
      }
      final raw = await ssh.exec(creds, tmuxSessionProbeCommand(session.tmuxName!));
      if (_disposed || generation != _connectGeneration) return;
      if (connectionRevision != session.connectionRevision) return;
      final present = parseTmuxSessionProbe(raw);
      if (present == null) throw SshConnectException(raw);
      if (!present) {
        await _app.repository.deletePersistentSession(server.id, session.tmuxName!);
        await _app.repository.updateHealthScore(server.id, -1);
        await markReachable?.call(server);
        await _reloadSaved();
        if (_disposed || generation != _connectGeneration) return;
        _reconnectRuns.remove(session)?.timer?.cancel();
        session.reconnecting = false;
        session.closeByUser();
        _error =
            'Tmux confirmed that this session no longer exists. Its recovery entry was removed; '
            'no empty replacement was created.';
      } else {
        await markReachable?.call(server);
        if (_disposed || generation != _connectGeneration) return;
        if (!session.isOpen) retrySession(session);
      }
    } catch (error) {
      if (!_disposed &&
          generation == _connectGeneration &&
          connectionRevision == session.connectionRevision) {
        _error =
            '${describeSshFailure('$error')} The tmux recovery entry was kept; '
            'retry when the host is available.';
        if (server != null) {
          if (sshFailureProvesEndpointUnreachable('$error')) session.markTransportUnavailable();
          await _app.repository.updateHealthScore(server.id, -1);
          unawaited(recheckHost?.call(server) ?? Future<void>.value());
        }
      }
    } finally {
      if (!_disposed && generation == _connectGeneration) {
        _connecting = false;
        _validationPane = null;
        _phase = null;
        _safeNotify();
      }
    }
  }

  // ── split view ──────────────────────────────────────────────────────────────

  /// Layout and focus belong to slots, including slots with no attached SSH channel.
  String? _splitId;
  String? _splitFirstId;
  bool _splitMode = false;
  int _focusedPane = 1;
  final _splitPaneRevisions = <int, int>{1: 0, 2: 0};
  final _splitPaneMessages = <int, String>{};
  final _splitPaneFailures = <int, ({_ShellConnectRequest request, String message})>{};
  _ShellConnectRequest? _activeConnectRequest;
  ShellSession? _connectingSession;
  int? _validationPane;
  _ShellConnectRequest? _pendingConnectRequest;
  _ShellConnectRequest? _failedConnectRequest;
  final _splitConnectQueue = <_ShellConnectRequest>[];
  int _splitQueueRevision = 0;
  int? _drainingSplitRevision;

  /// True when the panes stack vertically. The Kotlin calls these `⬍ STACK` and `⬌ COLS`.
  bool _splitStacked = true;
  bool get splitStacked => _splitStacked;

  ShellSession? get splitSession => focusedPane == 1 ? splitSecondSession : splitFirstSession;

  bool get isSplit => _splitMode;
  int get focusedPane => _focusedPane;
  ShellSession? get splitFirstSession => _sessions.where((s) => s.id == _splitFirstId).firstOrNull;
  ShellSession? get splitSecondSession => _sessions.where((s) => s.id == _splitId).firstOrNull;

  bool isPaneConnecting(int pane) =>
      (_connecting && (_activeConnectRequest?.pane == pane || _validationPane == pane)) ||
      (_tmuxInstalling && _pendingConnectRequest?.pane == pane);
  String? paneMessage(int pane) => _splitPaneMessages[pane];
  String? paneError(int pane) => _splitPaneFailures[pane]?.message;
  bool isPaneAwaitingDecision(int pane) => _pendingConnectRequest?.pane == pane;
  bool canRetryPane(int pane) => _splitPaneFailures.containsKey(pane);

  Future<void> retryPane(int pane) async {
    final failure = _splitPaneFailures[pane];
    if (failure == null || _pendingConnectRequest != null || _tmuxInstalling) return;
    await _connect(failure.request.continueWith(confirmedOffline: true));
  }

  List<ShellSession> splitCandidatesFor(int pane) =>
      _sessions.where((s) => s.id != (pane == 1 ? _splitId : _splitFirstId)).toList();

  /// Sessions that could occupy the second pane: everything except the one already in the first.
  List<ShellSession> get splitCandidates =>
      isSplit ? splitCandidatesFor(2) : _sessions.where((s) => s.id != current?.id).toList();

  void enterSplit() {
    if (isSplit) return;
    final first = current;
    _splitFirstId = first?.id;
    _splitId = null;
    _focusedPane = 1;
    _splitMode = true;
    _showConnectPrompt = false;
    _safeNotify();
  }

  void focusSplitPane(int pane) {
    if (!isSplit || (pane != 1 && pane != 2)) return;
    if (_focusedPane != pane) _resetPendingSmartInput();
    _focusedPane = pane;
    _currentId = (pane == 1 ? splitFirstSession : splitSecondSession)?.id;
    final selected = current;
    if (selected != null) _app.selectedServerId = selected.serverId;
    _safeNotify();
  }

  bool assignSplitPane(int pane, String id, {bool focus = true}) {
    if (!isSplit || (pane != 1 && pane != 2)) return false;
    if (!_sessions.any((s) => s.id == id)) return false;
    final other = pane == 1 ? splitSecondSession : splitFirstSession;
    if (other?.id == id) return false;
    _invalidatePane(pane);
    if (pane == 1) {
      _splitFirstId = id;
    } else {
      _splitId = id;
    }
    _backgroundedAt.remove(id);
    if (focus) focusSplitPane(pane);
    _offerSplitShortcut();
    _safeNotify();
    unawaited(_syncBackgroundSessions());
    return true;
  }

  void _invalidatePane(int pane) {
    if (_activeConnectRequest?.pane == pane ||
        _pendingConnectRequest?.pane == pane ||
        _validationPane == pane) {
      cancelConnect();
    }
    _splitPaneRevisions[pane] = _splitPaneRevisions[pane]! + 1;
    _splitPaneMessages.remove(pane);
    _splitPaneFailures.remove(pane);
    if (_failedConnectRequest?.pane == pane) clearError();
  }

  void _clearSplitSession(String id) {
    if (_splitFirstId == id) {
      _invalidatePane(1);
      _splitFirstId = null;
    }
    if (_splitId == id) {
      _invalidatePane(2);
      _splitId = null;
    }
    _currentId = current?.id;
  }

  /// Shows [id] in the second pane.
  void splitWith(String id) {
    if (id == current?.id && !isSplit) return;
    enterSplit();
    assignSplitPane(2, id, focus: false);
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
    final first = splitFirstSession;
    final second = splitSecondSession;
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
    return connectableServers.isNotEmpty;
  }

  /// Open a separate terminal without attaching a second client to an already displayed tmux PTY.
  Future<void> splitWithNewSession(Server server, {int pane = 2, String? resumeName}) async {
    if (pane != 1 && pane != 2) return;
    if (_connecting || _pendingConnectRequest != null || _tmuxInstalling) return;
    enterSplit();
    _invalidatePane(pane);
    if (pane == 1) {
      _splitFirstId = null;
    } else {
      _splitId = null;
    }
    if (resumeName != null) {
      final existing = _sessions
          .where((s) => s.serverId == server.id && s.tmuxName == resumeName)
          .firstOrNull;
      if (existing != null) {
        if (!assignSplitPane(pane, existing.id)) {
          _splitPaneMessages[pane] = 'That tmux session is already shown in the other pane.';
          _safeNotify();
        }
        return;
      }
    }
    await connect(
      server,
      pane: pane,
      resumeName: resumeName,
      controlMode: useControlMode,
      freshSession: resumeName == null,
    );
  }

  Future<void> resumeIntoSplitPane(PersistentSession row, int pane) async {
    if (pane != 1 && pane != 2) return;
    enterSplit();
    final revision = _splitPaneRevisions[pane];
    final host = await _app.repository.getServerById(row.serverId);
    if (_disposed || !isSplit || _splitPaneRevisions[pane] != revision) return;
    if (host == null) {
      _error = 'The host for this saved tmux session no longer exists. Restore the host first.';
      _safeNotify();
      return;
    }
    // A saved target is existing remote work, regardless of the host's default for new shells.
    await splitWithNewSession(
      host.copyWith(persistentSession: true),
      pane: pane,
      resumeName: row.tmuxName,
    );
  }

  /// Launcher pairs reuse live terminals and serialize connection dialogs through one owner.
  Future<void> openSplitForServers(Server first, Server second) async {
    if (first.id == second.id || _disposed) return;
    cancelConnect();
    enterSplit();
    _splitFirstId = null;
    _splitId = null;
    _focusedPane = 1;
    for (final entry in [(1, first), (2, second)]) {
      final pane = entry.$1;
      final host = entry.$2;
      _invalidatePane(pane);
      final existing = _sessions.where((s) => s.serverId == host.id && s.isOpen).firstOrNull;
      if (existing != null) {
        assignSplitPane(pane, existing.id, focus: false);
      } else {
        _splitConnectQueue.add(
          _ShellConnectRequest(
            server: host,
            controlMode: useControlMode,
            pane: pane,
            paneRevision: _splitPaneRevisions[pane],
          ),
        );
      }
    }
    focusSplitPane(1);
    await _drainSplitQueue();
  }

  Future<void> _drainSplitQueue() async {
    final revision = _splitQueueRevision;
    if (_drainingSplitRevision == revision) return;
    _drainingSplitRevision = revision;
    try {
      while (!_disposed &&
          revision == _splitQueueRevision &&
          !_connecting &&
          _pendingConnectRequest == null &&
          !_tmuxInstalling &&
          _splitConnectQueue.isNotEmpty) {
        final request = _splitConnectQueue.removeAt(0);
        if (_requestStillValid(request)) await _connect(request);
      }
    } finally {
      if (_drainingSplitRevision == revision) _drainingSplitRevision = null;
    }
  }

  void unsplit() {
    if (!isSplit) return;
    final keep = current ?? splitFirstSession ?? splitSecondSession;
    cancelConnect();
    _splitMode = false;
    _splitId = null;
    _splitFirstId = null;
    _focusedPane = 1;
    _splitPaneRevisions.updateAll((_, revision) => revision + 1);
    _splitPaneMessages.clear();
    _splitPaneFailures.clear();
    _currentId = keep?.id;
    _showConnectPrompt = keep == null;
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
    if (isSplit) {
      if (id == _splitFirstId) focusSplitPane(1);
      if (id == _splitId) focusSplitPane(2);
      return;
    }
    final session = _sessions.where((s) => s.id == id).firstOrNull;
    if (session == null) return;
    if (id == _currentId) return;
    _selectWithoutValidation(session);
  }

  bool _connecting = false;
  int _connectGeneration = 0;
  bool get isConnecting => _connecting;

  void cancelConnect() {
    if (!_connecting && _pendingConnectRequest == null && _splitConnectQueue.isEmpty) return;
    final pane = (_activeConnectRequest ?? _pendingConnectRequest)?.pane;
    final unfinished = _connectingSession;
    _connectGeneration++;
    _connecting = false;
    _activeConnectRequest = null;
    _connectingSession = null;
    _validationPane = null;
    _pendingConnectRequest = null;
    _offlineConnectPromptServer = null;
    _tmuxPromptServer = null;
    _splitConnectQueue.clear();
    _splitQueueRevision++;
    _phase = null;
    // The bootstrap may already have reached tmux; retain its recovery entry while closing only
    // this attempt's client. Revoke ownership before closing, which can notify slot listeners.
    if (unfinished != null && _sessions.contains(unfinished)) _close(unfinished);
    if (pane != null) _splitPaneMessages[pane] = 'Connection cancelled. Choose a session to retry.';
    _safeNotify();
  }

  String? _phase;

  /// Human-readable connection progress ("Authenticating…"), straight from the transport.
  String? get connectPhase => _phase;

  String? _error;
  String? get error => _error;
  Server? _failedConnectTarget;
  String? _failedResumeName;
  bool _failedControlMode = false;

  bool get canRetryConnection => _failedConnectTarget != null || current?.tmuxName != null;

  Future<void> retryConnection() async {
    final target = _failedConnectTarget;
    if (target != null) {
      final request = _failedConnectRequest;
      if (request != null) {
        await _connect(request.continueWith(confirmedOffline: true));
        return;
      }
      await connect(
        target,
        resumeName: _failedResumeName,
        controlMode: _failedControlMode,
        confirmedOffline: true,
      );
    } else if (current?.tmuxName != null) {
      await _validateExistingTmux(current!);
    }
  }

  void clearError() {
    if (_error == null) return;
    final pane = _failedConnectRequest?.pane;
    if (pane != null) _splitPaneFailures.remove(pane);
    _error = null;
    _failedConnectTarget = null;
    _failedConnectRequest = null;
    _safeNotify();
  }

  void _recordConnectFailure(Server server, String message) {
    _failedConnectTarget = server;
    _failedConnectRequest = _activeConnectRequest;
    _error = message.contains('recovery entry') ? message : describeSshFailure(message);
    _rememberPaneFailure(_activeConnectRequest, _error!);
    unawaited(_app.repository.updateHealthScore(server.id, -1));
    unawaited(recheckHost?.call(server) ?? Future<void>.value());
  }

  void _rememberPaneFailure(_ShellConnectRequest? request, String message) {
    final pane = request?.pane;
    if (request != null && pane != null && _requestStillValid(request)) {
      _splitPaneFailures[pane] = (request: request, message: message);
    }
  }

  /// Decides which tmux session a connection to [server] should join, creating a row if needed.
  ///
  /// [resumeName] forces a specific session — that is what the resumable list passes, so tapping a
  /// remembered session joins *that* one rather than whichever row happens to be newest.
  Future<(String name, String command)> _persistentTarget(
    Server server, {
    String? resumeName,
    bool controlMode = false,
    bool freshSession = false,
  }) async {
    final scrollback = PreferenceLimits.terminalScrollback.parse(
      await _app.repository.getSetting('terminal_scrollback_limit'),
    );
    final rows = (await _app.repository.getPersistentSessions())
        .where((row) => row.serverId == server.id)
        .toList();
    final existing = resumeName ?? (freshSession || rows.isEmpty ? null : rows.last.tmuxName);

    if (existing != null) {
      // The exact-name probe in connect() has already proved this row still exists. Attach only:
      // recreating an absent session here would disguise data loss as a successful recovery.
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
    await _app.repository.deletePersistentSession(row.serverId, row.tmuxName);
    await _reloadSaved();
  }

  /// Opens a saved session again, attaching to that exact tmux name.
  Future<void> resume(PersistentSession row) async {
    final existing = _sessions
        .where((s) => s.tmuxName == row.tmuxName && s.serverId == row.serverId)
        .firstOrNull;
    if (existing != null) {
      _selectWithoutValidation(existing);
      await _validateExistingTmux(existing);
      return;
    }
    final server = _app.servers.where((s) => s.id == row.serverId).firstOrNull;
    if (server == null) {
      _error = 'The host this session ran on is no longer saved.';
      _safeNotify();
      return;
    }
    // The saved row identifies existing remote work. Changing a host's default for NEW sessions
    // must not turn Resume into a fresh plain shell, nor ignore the selected control-mode setting.
    await connect(
      server.copyWith(persistentSession: true),
      resumeName: row.tmuxName,
      controlMode: useControlMode,
    );
  }

  /// Stamps when [serverId]'s [tmuxName] stopped being watched.
  ///
  /// Read-then-write rather than a partial update: the row carries the host it belongs to and
  /// whether it was adopted, and rewriting it from anything but itself would be how a session ends
  /// up attributed to the wrong machine, or has its user's tmux options changed.
  Future<void> _markBackgrounded(
    int serverId,
    String tmuxName, {
    bool requireRecord = false,
    bool reload = true,
  }) async {
    final row = (await _app.repository.getPersistentSessions())
        .where((r) => r.serverId == serverId && r.tmuxName == tmuxName)
        .firstOrNull;
    if (row == null) {
      if (requireRecord) throw StateError('The saved tmux recovery record is missing.');
      return;
    }
    await _app.repository.upsertPersistentSession(
      PersistentSessionsCompanion.insert(
        tmuxName: row.tmuxName,
        serverId: row.serverId,
        serverName: row.serverName,
        createdAt: row.createdAt,
        backgroundedAt: DateTime.now().millisecondsSinceEpoch,
        adopted: Value(row.adopted),
      ),
    );
    if (reload) await _reloadSaved();
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
  /// Drops pinned host keys for "Remove & Reconnect"; null where the app has no trust store.
  final SshHostKeyTrust? hostKeyTrust;

  Server? _hostKeyChangedServer;

  /// A host whose SSH key no longer matches the pinned one, awaiting the user's decision (Kotlin's
  /// "Host Key Changed" dialog).
  Server? get hostKeyChangedServer => _hostKeyChangedServer;

  void dismissHostKeyChanged() {
    if (_hostKeyChangedServer == null) return;
    _hostKeyChangedServer = null;
    _failedConnectTarget = null;
    _failedConnectRequest = null;
    _safeNotify();
  }

  /// Kotlin's `removeTrustedKeyAndRetry`: forget the pinned key, then connect again, which shows
  /// the new key's fingerprint for approval like any first connection.
  Future<void> removeTrustedKeyAndRetry() async {
    final server = _hostKeyChangedServer;
    if (server == null) return;
    _hostKeyChangedServer = null;
    _safeNotify();
    await hostKeyTrust?.removeHost(server.host, server.port);
    await retryConnection();
  }

  Server? get offlineConnectPromptServer => _offlineConnectPromptServer;
  Server? _offlineConnectPromptServer;

  void dismissOfflineConnectPrompt() {
    if (_offlineConnectPromptServer == null) return;
    cancelConnect();
  }

  /// Re-enters [connect] with the offline gate bypassed.
  Future<void> connectConfirmedOffline() async {
    final request = _pendingConnectRequest;
    if (_offlineConnectPromptServer == null || request == null) return;
    _offlineConnectPromptServer = null;
    _pendingConnectRequest = null;
    _safeNotify();
    await _connect(request.continueWith(confirmedOffline: true));
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
    cancelConnect();
    _tmuxInstallOutput = null;
    _safeNotify();
  }

  /// Connects anyway, accepting an ordinary non-resumable shell.
  Future<void> connectWithoutPersistence() async {
    final request = _pendingConnectRequest;
    if (_tmuxPromptServer == null || request == null) return;
    _tmuxPromptServer = null;
    _pendingConnectRequest = null;
    _tmuxInstallOutput = null;
    await _connect(request.continueWith(forcePlainShell: true));
  }

  /// Installs tmux on the prompted host, then connects with persistence.
  Future<void> installTmuxAndConnect() async {
    final server = _tmuxPromptServer;
    final request = _pendingConnectRequest;
    final ssh = transport;
    if (server == null || request == null || ssh == null || _tmuxInstalling) return;
    final generation = _connectGeneration;
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
          if (_disposed || generation != _connectGeneration) return;
          _tmuxInstallOutput = (_tmuxInstallOutput ?? '') + chunk;
          _safeNotify();
        },
      );
      // Re-probed rather than trusting the installer's exit code, for the same reason the script
      // re-checks itself: a package manager can report success against a broken mirror. Only a
      // definite yes counts — an unanswered probe is not proof the install worked.
      installed = await _hasTmux(server) ?? false;
    } catch (e) {
      _tmuxInstallOutput = '${_tmuxInstallOutput ?? ''}\n\n$e';
    }
    if (_disposed || generation != _connectGeneration || !_requestStillValid(request)) {
      _tmuxInstalling = false;
      _safeNotify();
      return;
    }
    _tmuxInstalling = false;

    if (!installed) {
      _tmuxInstallOutput =
          '${_tmuxInstallOutput ?? ''}\n\nInstall did not complete. You can retry, '
          'connect non-resumable, or install tmux manually.';
      _safeNotify();
      return;
    }
    _tmuxVerified.add(server.id);
    _tmuxPromptServer = null;
    _pendingConnectRequest = null;
    _tmuxInstallOutput = null;
    await _connect(request);
  }

  /// `true` present, `false` definitely absent, `null` the probe could not answer.
  ///
  /// A probe that could not run is not evidence tmux is missing, and only a definite `false` is
  /// allowed to offer an install. `null` lets the real connection attempt report the real
  /// transport error; remembered rows receive the stricter exact-name authenticated probe in
  /// [connect] before any shell is opened.
  Future<bool?> _hasTmux(Server server) async {
    final ssh = transport;
    if (ssh == null) return null;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      // Not `endsWith('yes')` on the raw answer: `exec` returns `'SSH Error: …'` instead of
      // throwing, so every failure that did not happen to end in "yes" used to read as a
      // definite "tmux is missing" and offered to install a package over a dead connection.
      return parseTmuxCheck(await ssh.exec(creds, tmuxCheckCommand));
    } catch (_) {
      return null;
    }
  }

  /// False for a Windows host. Answers true when the host cannot be asked, so a failed probe never
  /// downgrades a persistent session on its own.
  Future<bool> _hasUnixShell(Server server) async {
    final ssh = transport;
    if (ssh == null) return true;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      return hasUnixShell(await _app.hostOs(server.id, (command) => ssh.exec(creds, command)));
    } catch (_) {
      return true;
    }
  }

  /// Saved key aliases and credential profiles, offered by the Quick connect dialog.
  Future<List<String>> savedKeyAliases() async =>
      (await _app.repository.getAllKeys()).map((k) => k.alias).toList();

  Future<List<CredentialProfile>> savedProfiles() => _app.repository.getAllProfiles();

  /// Every saved host, offered by Quick connect as a jump host.
  List<Server> get savedServers => List.unmodifiable(_app.servers);

  int _nextAdHocServerId = -1;

  /// Connects to a host that is not saved, as Kotlin's `AppViewModel.quickConnect` does. Returns
  /// why [input] was rejected so the dialog can stay open, or null once the connection has started;
  /// how an accepted connection goes is reported by the terminal itself.
  String? quickConnect(QuickConnectInput input) {
    final error = quickConnectError(input, connecting: isConnecting);
    if (error != null) return error;
    final adHoc = quickConnectServer(input, id: _nextAdHocServerId--);
    // A one-off host replaces the split view rather than landing in whichever pane had focus.
    unsplit();
    unawaited(connect(adHoc));
    return null;
  }

  Future<void> connect(
    Server server, {
    String? resumeName,
    bool controlMode = false,
    String? initialCommand,
    bool forcePlainShell = false,
    bool confirmedOffline = false,
    bool freshSession = false,
    int? pane,
  }) async {
    if (_connecting || _pendingConnectRequest != null || _tmuxInstalling || _disposed) return;
    final destination = isSplit ? pane ?? focusedPane : null;
    if (destination != null) {
      if (destination != 1 && destination != 2) return;
      _invalidatePane(destination);
    }
    await _connect(
      _ShellConnectRequest(
        server: server,
        resumeName: resumeName,
        controlMode: controlMode,
        initialCommand: initialCommand,
        forcePlainShell: forcePlainShell,
        confirmedOffline: confirmedOffline,
        freshSession: freshSession || (destination != null && resumeName == null),
        pane: destination,
        paneRevision: destination == null ? null : _splitPaneRevisions[destination],
      ),
    );
  }

  bool _requestStillValid(_ShellConnectRequest request) =>
      !_disposed &&
      (request.pane == null ||
          (isSplit && _splitPaneRevisions[request.pane] == request.paneRevision));

  Future<void> _connect(_ShellConnectRequest request) async {
    if (_connecting || !_requestStillValid(request)) return;
    final server = request.server;
    final resumeName = request.resumeName;
    final controlMode = request.controlMode;
    final initialCommand = request.initialCommand;
    var forcePlainShell = request.forcePlainShell;
    final confirmedOffline = request.confirmedOffline;
    final other = request.pane == 1 ? splitSecondSession : splitFirstSession;
    if (request.pane != null &&
        resumeName != null &&
        other?.serverId == server.id &&
        other?.tmuxName == resumeName) {
      _splitPaneMessages[request.pane!] =
          'That tmux session is already shown in the other pane. Choose another session.';
      _safeNotify();
      return;
    }

    // Checked before the tmux probe, which costs a round trip: there is no point asking a host
    // whether it has tmux when the last check said it was not answering at all.
    if (!confirmedOffline &&
        shouldWarnHostOffline(probed: hasProbed?.call(server.id) ?? false, status: server.status)) {
      _offlineConnectPromptServer = server;
      _pendingConnectRequest = request;
      _safeNotify();
      return;
    }
    final ssh = transport;
    if (ssh == null) {
      _error = 'The terminal is unavailable in this build: no SSH transport is wired.';
      _rememberPaneFailure(request, _error!);
      _safeNotify();
      return;
    }

    _connecting = true;
    _activeConnectRequest = request;
    final generation = ++_connectGeneration;
    _phase = 'Connecting…';
    _error = null;
    _failedConnectTarget = null;
    _failedConnectRequest = null;
    if (request.pane != null) {
      _splitPaneMessages.remove(request.pane);
      _splitPaneFailures.remove(request.pane);
    }
    _failedResumeName = resumeName;
    _failedControlMode = controlMode;
    _safeNotify();

    (String, String)? persistent;
    try {
      // A host configured for persistent sessions but missing tmux used to connect as an ordinary
      // shell with no notice: the user believed their work survived a dropped link, and it did not.
      // Probed once per host per session; the answer is only acted on when it is a definite "no".
      //
      // Inside the attempt, not before it. This probe is a round trip to the host and used to run
      // with `_connecting` still false: no busy state while it was in flight, `cancelConnect` had
      // nothing to cancel, and the `if (_connecting) return` guard at the top of this method could
      // not see it — so a second tap during a slow probe started a second full connection.
      if (server.persistentSession && !forcePlainShell && !_tmuxVerified.contains(server.id)) {
        _phase = 'Checking for tmux…';
        _safeNotify();
        final present = await _hasTmux(server);
        // Cancelled or superseded while the probe was in flight: `finally` below leaves the newer
        // attempt's state alone, and this one must not raise a prompt for an abandoned connection.
        if (generation != _connectGeneration) return;
        if (present == true) {
          _tmuxVerified.add(server.id);
        } else if (present == false && !await _hasUnixShell(server)) {
          // Windows has no tmux: an ordinary shell, not an offer to install the impossible.
          if (generation != _connectGeneration) return;
          forcePlainShell = true;
        } else if (present == false) {
          _tmuxPromptServer = server;
          _pendingConnectRequest = request;
          _tmuxInstallOutput = null;
          return;
        }
        // `null` is an unverified probe, not an absent tmux. Carry on and let the connection
        // itself surface whatever is actually wrong with the host.
        _phase = 'Connecting…';
        _safeNotify();
      }
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
      if (server.persistentSession && !forcePlainShell) {
        final remembered =
            resumeName ??
            (request.freshSession
                ? null
                : (await _app.repository.getPersistentSessions())
                      .where((row) => row.serverId == server.id)
                      .lastOrNull
                      ?.tmuxName);
        if (remembered != null) {
          String rawPresence;
          try {
            rawPresence = await ssh.exec(creds, tmuxSessionProbeCommand(remembered));
          } catch (error) {
            throw SshConnectException(
              'Could not verify the saved tmux session because the host could not be reached. '
              'The recovery entry was kept; retry when the connection is available. $error',
              error,
            );
          }
          if (generation != _connectGeneration || !_requestStillValid(request)) return;
          final presence = parseTmuxSessionProbe(rawPresence);
          if (presence == null) {
            throw SshConnectException(
              'Could not verify the saved tmux session. The recovery entry was kept; retry when '
              'the connection is available. ${describeSshFailure(rawPresence)}',
            );
          }
          if (!presence) {
            await _app.repository.deletePersistentSession(server.id, remembered);
            await _app.repository.updateHealthScore(server.id, -1);
            await _reloadSaved();
            if (generation != _connectGeneration || !_requestStillValid(request)) return;
            unawaited(markReachable?.call(server) ?? Future<void>.value());
            _failedConnectTarget = server;
            _failedConnectRequest = request;
            _error =
                'Connected to ${server.name}, but tmux confirmed that "$remembered" no longer '
                'exists. Its recovery entry was removed; no empty replacement was created.';
            _rememberPaneFailure(request, _error!);
            return;
          }
        }
      }
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
      // From here until a ShellSession takes it, this attempt owns the channel — and owning it
      // means closing it on *every* way out, not just the two that were checked. `_persistentTarget`
      // below does real database work, and when that threw the exception unwound straight past an
      // open SSH shell: not in `_sessions`, invisible to the user, holding a channel on the server
      // until the process died. The flag flips the instant ownership transfers.
      var channelAdopted = false;
      final ShellSession session;
      try {
        if (generation != _connectGeneration || !_requestStillValid(request)) return;
        final emulator = TerminalEmulator(
          cols: _preferredCols,
          rows: _preferredRows,
          scrollbackLimit: scrollbackLimit,
        );
        // Resolved before the session is built so it can carry its own tmux name — that is what
        // lets the resumable list tell "open in a tab" from "running with nobody watching".
        final persistentTarget = server.persistentSession && !forcePlainShell
            ? await _persistentTarget(
                server,
                resumeName: resumeName,
                controlMode: controlMode,
                freshSession: request.freshSession,
              )
            : null;
        if (generation != _connectGeneration || !_requestStillValid(request)) return;
        persistent = persistentTarget;

        session = ShellSession(
          id: '${DateTime.now().microsecondsSinceEpoch}-${server.id}',
          serverId: server.id,
          serverName: server.name,
          channel: channel,
          emulator: emulator,
          tmuxName: persistentTarget?.$1,
          // Only a host that actually went into tmux can be in control mode; a plain shell that
          // was asked for it would have its ordinary output parsed as a protocol and rendered as
          // nothing.
          controlMode: controlMode && persistentTarget != null,
        )..setViewportRows(_preferredRows);
        channelAdopted = true;
      } finally {
        if (!channelAdopted) {
          try {
            channel.close();
          } catch (_) {
            // Closing a channel that already died must not replace the real failure being thrown.
          }
        }
      }
      // The parser must not block on repaint; the session buffers input until the pane is ready.
      session.setReadOnly(_terminalReadOnly);
      session.onPaneChanged = (changed) => unawaited(refreshControlActivePane(changed));
      session.addListener(_onSessionChanged);
      session.addListener(_syncBackgroundSessions);
      session.addListener(_syncReachabilityEvidence);
      _sessions.add(session);
      _connectingSession = session;
      _sessionCredentials[session] = creds;
      _sessionHosts[session] = server;
      if (request.pane != null) {
        if (request.pane == 1) {
          _splitFirstId = session.id;
        } else {
          _splitId = session.id;
        }
        _currentId = current?.id;
        _offerSplitShortcut();
      } else {
        _currentId = session.id;
      }
      _showConnectPrompt = false;
      _failedConnectTarget = null;
      _syncReachabilityEvidence();
      if (generation != _connectGeneration || !_requestStillValid(request)) return;

      // A shell channel opened, so any earlier advisory reachability result is stale. Do not make
      // the user fight the same false offline warning on their next connection.
      unawaited(markReachable?.call(server) ?? Future<void>.value());

      // A session that reached this point authenticated and opened a channel, which is the only
      // definition of "it worked" worth counting. Fire-and-forget: the terminal must not wait on a
      // settings write, and a failed nudge is never the user's problem.
      unawaited(reviewPrompt?.noteSuccessfulSession() ?? Future<void>.value());

      // A host marked "persistent" is put inside tmux immediately, which is the whole point: a
      // dropped link then leaves the work running on the server instead of killing it. Written as
      // the shell's first input rather than run as a channel command, so a host without tmux is
      // left at a perfectly ordinary prompt (the command guards itself with `command -v tmux`).
      if (persistent != null) {
        // This is the shell bootstrap, not user input on an established control channel.
        try {
          await channel.write(Uint8List.fromList(utf8.encode(persistent.$2)));
          if (generation != _connectGeneration || !_requestStillValid(request)) return;
        } catch (_) {
          session.closeByUser();
          rethrow;
        }
        // Bookkeeping, and the session is already registered and usable. Letting this throw sent a
        // live shell's connection into the failure handlers below, which told the user the
        // connection had failed while their working terminal sat in front of them. The list being
        // stale is worth saying — it is what Leave and resume read — but it is not a failed
        // connect, and the refresh is retried whenever anything else reloads it.
        try {
          await _reloadSaved();
        } catch (error) {
          if (generation == _connectGeneration) {
            _error =
                'Connected to ${server.name}. The resumable-session list could not be refreshed, '
                'so it may be out of date until the next change: ${describeSshFailure('$error')}';
            _safeNotify();
          }
        }
      }
      if (generation != _connectGeneration || !_requestStillValid(request)) return;
      if (initialCommand != null && initialCommand.trim().isNotEmpty) {
        session.write(Uint8List.fromList(utf8.encode('${initialCommand.trim()}\r')));
      }
      _syncBackgroundSessions();
    } on CredentialResolutionException catch (e) {
      if (generation == _connectGeneration) {
        _recordConnectFailure(server, e.message);
      }
    } on SshHostKeyException catch (e) {
      // Named separately from an auth failure because the fix is different and the stakes are
      // different: "wrong password" is a nuisance, "this host's key changed" is either a rebuilt
      // server or someone standing between you and it, and the app must not blur the two.
      if (generation == _connectGeneration) {
        _failedConnectTarget = server;
        _failedConnectRequest = request;
        if (e.verdict == HostKeyVerdict.changed) {
          // Kotlin's "Host Key Changed" dialog: the decision is put to the user there, with
          // "Remove & Reconnect" for a server that was legitimately rebuilt.
          _hostKeyChangedServer = server;
        } else {
          _error = 'Host key rejected by user.';
          _rememberPaneFailure(request, _error!);
        }
      }
    } on SshConnectException catch (e) {
      if (generation == _connectGeneration) {
        _recordConnectFailure(server, e.message);
      }
    } catch (e) {
      if (generation == _connectGeneration) {
        _recordConnectFailure(server, e.toString());
      }
    } finally {
      if (generation == _connectGeneration) {
        _connecting = false;
        _activeConnectRequest = null;
        _connectingSession = null;
        _phase = null;
        _safeNotify();
        if (_pendingConnectRequest == null) unawaited(_drainSplitQueue());
      }
    }
  }

  /// Close and forget a session.
  ///
  /// For a persistent host this is *not* the end of the work: the tmux session keeps running on the
  /// server, which is the entire point of marking a host persistent. So closing the tab starts that
  /// session's "left running since" clock — without it the resumable list cannot tell a session
  /// abandoned two minutes ago from one abandoned last month, and Forget is a decision made blind.
  void close(ShellSession session) => _close(session);

  void _close(ShellSession session, {bool saveRecovery = true}) {
    _reconnectRuns.remove(session)?.timer?.cancel();
    _sessionCredentials.remove(session);
    _sessionHosts.remove(session);
    _paneAltCache.remove(session);
    session.reconnecting = false;
    final tmuxName = session.tmuxName;
    if (tmuxName != null && saveRecovery) {
      unawaited(
        _markBackgrounded(session.serverId, tmuxName).catchError((Object error) {
          _error = 'Could not update the saved tmux recovery record: $error';
          _safeNotify();
        }),
      );
    }
    session.closeByUser();
    session.removeListener(_onSessionChanged);
    session.removeListener(_syncBackgroundSessions);
    session.removeListener(_syncReachabilityEvidence);
    _sessions.remove(session);
    _backgroundedAt.remove(session.id);
    if (isSplit) {
      _clearSplitSession(session.id);
    } else if (_currentId == session.id) {
      _currentId = _sessions.isEmpty ? null : _sessions.last.id;
    }
    session.dispose();
    _syncReachabilityEvidence();
    _syncBackgroundSessions();
    _safeNotify();
  }

  /// Terminates a persistent tmux session on the host, then closes its local SSH channel.
  Future<void> terminate(ShellSession session) async {
    final failure = await _terminate(session);
    if (failure == null) return;
    _error = failure;
    _safeNotify();
  }

  /// Terminates one session and *returns* its failure instead of publishing it.
  ///
  /// Returning rather than assigning is what lets [disconnectAll] report every host that failed:
  /// writing straight to `_error` in a loop meant the second failure overwrote the first, so a user
  /// disconnecting three hosts saw one message and had no idea the other two were still running on
  /// their servers.
  Future<String?> _terminate(ShellSession session) async {
    final tmuxName = session.tmuxName;
    if (tmuxName == null) {
      close(session);
      return null;
    }
    final server = _app.servers.where((server) => server.id == session.serverId).firstOrNull;
    var confirmedStopped = false;
    try {
      if (server == null || transport == null) {
        throw StateError('The host or SSH transport is no longer available.');
      }
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final result = await transport!.exec(creds, tmuxKillCommand(tmuxName));
      if (result.startsWith('SSH Error:')) throw StateError(result);
      final presence = parseTmuxSessionProbe(
        await transport!.exec(creds, tmuxSessionProbeCommand(tmuxName)),
      );
      if (presence != false) throw StateError('Tmux did not confirm that this session is gone.');
      await _app.repository.deletePersistentSession(session.serverId, tmuxName);
      await _reloadSaved();
      confirmedStopped = true;
      return null;
    } catch (e) {
      return 'Disconnected locally, but the remote tmux session could not be confirmed stopped. '
          'It remains available for recovery: $e';
    } finally {
      _close(session, saveRecovery: !confirmedStopped);
    }
  }

  /// True while [disconnectAll] is working, so the action that started it can show it and refuse
  /// to start a second one.
  ///
  /// Each persistent session costs two SSH round trips — kill, then confirm — so disconnecting a
  /// handful of hosts is seconds of work that previously showed nothing at all and left its own
  /// button enabled throughout.
  bool get isDisconnectingAll => _disconnectingAll;
  bool _disconnectingAll = false;

  Future<void> disconnectAll({bool terminatePersistent = true}) async {
    if (_disconnectingAll) return;
    _disconnectingAll = true;
    _error = null;
    _safeNotify();
    final failures = <String>[];
    try {
      cancelConnect();
      for (final session in _sessions.toList()) {
        if (terminatePersistent && session.tmuxName != null) {
          // Collected, not published one at a time: every host that could not be confirmed stopped
          // has to survive into the final message, because each is a session still running on a
          // server the user believes they have just shut down.
          final failure = await _terminate(session);
          if (failure != null) failures.add('${session.serverName}: $failure');
        } else {
          close(session);
        }
      }
    } finally {
      _disconnectingAll = false;
      if (failures.isNotEmpty) {
        _error = failures.length == 1
            ? failures.single
            : '${failures.length} sessions could not be confirmed stopped.\n'
                  '${failures.join('\n')}';
      }
      _safeNotify();
    }
  }

  bool _isLeavingSessions = false;
  bool get isLeavingSessions => _isLeavingSessions;

  Future<bool> leaveResumable(ShellSession session) => _leaveResumableSessions([session]);

  /// Save recovery metadata before closing a client. Never claim a successful leave first.
  Future<bool> _leaveResumableSessions(List<ShellSession> sessions) async {
    if (_isLeavingSessions || _disposed) return false;
    _isLeavingSessions = true;
    _error = null;
    _safeNotify();
    final resumeRevision = _terminalResumeRevision;
    try {
      final persistent = sessions
          .where((session) => session.tmuxName != null && _sessions.contains(session))
          .toList();
      // Match Kotlin: commit every recovery record before closing any client. Neither an
      // intermediate saved-list notification nor a failed later write can leave half the split.
      await _app.repository.inTransaction(() async {
        for (final session in persistent) {
          if (_disposed || resumeRevision != _terminalResumeRevision) throw _LeaveSuperseded();
          await _markBackgrounded(
            session.serverId,
            session.tmuxName!,
            requireRecord: true,
            reload: false,
          );
          if (_disposed || resumeRevision != _terminalResumeRevision) throw _LeaveSuperseded();
        }
      });
      if (_disposed || resumeRevision != _terminalResumeRevision) return false;
      await _reloadSaved();
      if (_disposed || resumeRevision != _terminalResumeRevision) return false;
      for (final session in persistent) {
        if (_sessions.contains(session)) _close(session, saveRecovery: false);
      }
      return true;
    } catch (error) {
      if (_disposed || resumeRevision != _terminalResumeRevision) return false;
      _error =
          'Could not save session recovery. Every live tab was kept open; retry leaving: $error';
      return false;
    } finally {
      _isLeavingSessions = false;
      _safeNotify();
    }
  }

  /// Detaches persistent sessions so tmux can be resumed; ordinary sessions stay connected.
  Future<bool> leaveOrBackgroundAll() => _leaveResumableSessions(_sessions.toList());

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
  ///
  /// Each terminal keeps its own ([ShellSession.ctrlArmed]); with none open there is nothing to
  /// arm them for.
  bool get ctrl => current?.ctrlArmed ?? false;
  set ctrl(bool value) => current?.ctrlArmed = value;
  bool get alt => current?.altArmed ?? false;
  set alt(bool value) => current?.altArmed = value;
  bool get shift => current?.shiftArmed ?? false;
  set shift(bool value) => current?.shiftArmed = value;

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

  ({Object owner, ShellSession session, VoidCallback reset})? _smartInput;

  /// The focused input owns this callback, as in Kotlin's pendingSwipeFlush. Reset synchronously
  /// before shell-owned input; waiting for a rebuild would leave a stale IME edit between frames.
  void registerSmartInput(Object owner, ShellSession session, VoidCallback reset) {
    if (_disposed || !identical(current, session)) return;
    _smartInput = (owner: owner, session: session, reset: reset);
  }

  void unregisterSmartInput(Object owner) {
    if (identical(_smartInput?.owner, owner)) _smartInput = null;
  }

  void _resetPendingSmartInput() {
    final pending = _smartInput;
    if (pending != null && identical(pending.session, current)) pending.reset();
  }

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

    if (!session.isOpen) return false;
    _resetPendingSmartInput();

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

  /// A raw or control-mode channel knows its own alternate screen. Regular tmux attach does not:
  /// its outer client uses one even when the pane is a plain shell, so ask the pane over SSH.
  /// The short cache keeps a drag from opening an exec channel for every pointer delta.
  Future<bool> isPaneTuiActiveFor(ShellSession session) async {
    if (!_sessions.contains(session) || !session.isOpen) return false;
    final name = session.tmuxName;
    if (name == null || session.controlMode) return session.emulator.isAlternateScreenActive;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _paneAltCache[session];
    final age = cached == null ? -1 : now - cached.checkedAtMs;
    if (cached != null && age >= 0 && age < 2500) return cached.active;

    final ssh = transport;
    final credentials = _sessionCredentials[session];
    if (ssh == null || credentials == null) return false;
    try {
      final answer = await ssh
          .exec(credentials, tmuxAlternateOnQuery(name))
          .timeout(const Duration(milliseconds: 600));
      if (!_sessions.contains(session) || !session.isOpen) return false;
      final active = answer.trim() == '1';
      _paneAltCache[session] = (active: active, checkedAtMs: DateTime.now().millisecondsSinceEpoch);
      return active;
    } catch (_) {
      return false;
    }
  }

  /// Deliver one gesture's capped page keys to the pane it touched, even in split view.
  bool sendPageKeysFor(ShellSession session, {required bool up, required int count}) {
    if (!_sessions.contains(session) || !session.isOpen || session.readOnly || count <= 0) {
      return false;
    }
    final key = TerminalKeyEncoder.encode(
      up ? TermKey.pageUp : TermKey.pageDown,
      applicationCursorKeys: session.emulator.applicationCursorKeys,
    );
    final capped = count.clamp(1, 3);
    final bytes = Uint8List(key.length * capped);
    for (var i = 0; i < capped; i++) {
      bytes.setRange(i * key.length, (i + 1) * key.length, key);
    }
    return session.write(bytes);
  }

  /// Send typed text under the current modifiers.
  bool typeText(String text) {
    final session = current;
    if (session == null || session.readOnly || !session.isOpen || text.isEmpty) return false;
    _resetPendingSmartInput();
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

    session.controlRefreshing = true;
    session.controlRefreshError = null;
    session.publishNow();
    try {
      final creds = resolveCredentials(
        host,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      // Retry rather than return: a switch that lands while the query is in flight would otherwise
      // be answered with the pane the user has just left.
      while (session.isOpen) {
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
        if (!RegExp(r'^%\d+$').hasMatch(paneId)) {
          throw StateError('The active tmux pane could not be resolved');
        }
        if (session.paneChangeRevision != revision) continue;
        if (await session.repaintControlPane(paneId, revision)) return true;
      }
      return false;
    } catch (error) {
      if (session.isOpen) {
        session.controlRefreshError =
            'Could not refresh the tmux pane: $error. Retry to send held input.';
      }
      return false;
    } finally {
      _paneRefreshing.remove(session);
      session.controlRefreshing = false;
      session.publishNow();
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
    if (name == null || ssh == null || !session.scrollbackDirty || _resyncing) {
      return 0;
    }
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

  /// Send immediate input as one contiguous write, preserving the bounded control-pane queue.
  bool paste(String text) {
    final session = current;
    if (session == null || text.isEmpty) return false;
    return session.write(encodePastedText(text, bracketed: session.emulator.bracketedPasteMode));
  }

  /// Clipboard reads and confirmation dialogs must never redirect a paste to a newer pane/channel.
  Future<bool> pasteTo(
    ShellSession session,
    String text, {
    required int connectionRevision,
    required int paneChangeRevision,
  }) async {
    if (_disposed ||
        !identical(current, session) ||
        !_sessions.contains(session) ||
        session.connectionRevision != connectionRevision ||
        session.paneChangeRevision != paneChangeRevision ||
        !session.isOpen ||
        session.readOnly ||
        text.isEmpty) {
      return false;
    }
    // A stuck modifier never rewrites pasted bytes. Bracketed mode is read at the moment of sending.
    return session.writeAndWait(
      encodePastedText(text, bracketed: session.emulator.bracketedPasteMode),
      connectionRevision: connectionRevision,
      paneChangeRevision: paneChangeRevision,
    );
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
    _smartInput = null;
    for (final run in _reconnectRuns.values) {
      run.timer?.cancel();
    }
    _reconnectRuns.clear();
    _sessionCredentials.clear();
    _sessionHosts.clear();
    _backgroundedAt.clear();
    _paneAltCache.clear();
    _app.removeListener(_onAppChanged);
    unawaited(_actionsSub?.cancel());
    for (final session in _sessions) {
      session.removeListener(_onSessionChanged);
      session.removeListener(_syncBackgroundSessions);
      session.removeListener(_syncReachabilityEvidence);
      session.dispose();
    }
    _sessions.clear();
    _lastLiveSessionServers = <int>{};
    syncLiveSessionServers?.call(const <int>{});
    // The service outlives this object, so it has to be told. A foreground notification left
    // standing over nothing is exactly the kind of thing users uninstall an app for.
    unawaited(sessionService?.stop());
    super.dispose();
  }
}

class _ReconnectRun {
  int attempt = 0;
  Timer? timer;
}
