import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/remote_parsers.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/command_danger.dart';
import '../../domain/health_scoring.dart';
import '../../domain/server_credentials.dart';
import '../../platform/long_operation_notifications.dart';
import 'app_state.dart';
import 'telemetry_poller.dart';

/// The Fleet screen's three tabs, in the Kotlin's order (`ui/FleetScreen.kt` line 59).
enum FleetTab { dashboard, broadcast, logs }

/// Whether a broadcast targets individually picked hosts or whole groups.
enum FleetTargetMode { servers, groups }

enum BroadcastStatus { pending, running, success, failure, cancelled }

/// One host's result within a broadcast.
class BroadcastResult {
  BroadcastResult({required this.serverId, required this.serverName});

  final int serverId;
  final String serverName;

  BroadcastStatus status = BroadcastStatus.pending;

  /// Output accumulated as it streams in, so a long-running command shows progress rather than
  /// nothing until it finishes.
  final StringBuffer output = StringBuffer();

  /// Set when the run failed, or when it succeeded with nothing to show.
  String? note;

  bool get isDone =>
      status == BroadcastStatus.success ||
      status == BroadcastStatus.failure ||
      status == BroadcastStatus.cancelled;
}

/// The Fleet screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
class FleetViewModel extends ChangeNotifier {
  FleetViewModel(this._app, {this.transport, this.poller, this.operationNotifications}) {
    _app.addListener(_onAppChanged);
    poller?.addListener(_safeNotify);
  }

  final AppState _app;
  final LongOperationNotifications? operationNotifications;
  int _operationSequence = 0;

  /// Null in tests and in any build without a transport wired; broadcasting is then unavailable and
  /// says so, rather than reporting a run that never happened.
  final SshTransport? transport;

  bool get canBroadcast => transport != null;

  /// The fleet-wide telemetry loop, when one is running.
  ///
  /// Fleet reads the poller rather than fetching for itself. It is the one screen showing every
  /// host at once, so a per-screen fetch here would mean N more SSH sessions every time someone
  /// opens the dashboard — on top of the ones the poller already opened for the same numbers.
  final TelemetryPoller? poller;

  /// When the next telemetry cycle is due, for the summary bar's countdown.
  DateTime? get nextRefreshAt => poller?.nextCycleAt;

  /// The recent CPU readings for [serverId], oldest first. Empty without a poller, because one
  /// on-demand fetch cannot support a claim about how something changed over time.
  List<double> cpuHistoryFor(int serverId) =>
      poller?.historyForServer(serverId).map((s) => s.metrics.cpuPercent).toList() ?? const [];

  /// When each of those readings was taken, for the chart's end labels.
  List<int> historyTimestampsFor(int serverId) =>
      poller?.historyForServer(serverId).map((s) => s.at.millisecondsSinceEpoch).toList() ??
      const [];

  /// Why [server] scores what it does, from the same config and readings the poller scored with.
  ///
  /// Null when nothing has sampled this host yet: an explanation assembled from
  /// [HostMetrics.empty] would read as a host at 0% on every metric, which is a description of a
  /// machine that does not exist.
  HealthBreakdown? healthBreakdownFor(Server server) {
    final metrics = poller?.metricsForServer(server.id);
    if (metrics == null) return null;
    return _app.healthScoring.breakdown(
      metrics.cpuPercent,
      metrics.memPercent,
      metrics.diskPercent,
      server.lastLatency,
      online: server.status == 'online',
    );
  }

  /// How many hosts a broadcast talks to at once.
  ///
  /// Unbounded fan-out would open one SSH connection per host simultaneously — on a large fleet that
  /// is a self-inflicted connection storm, and on a phone it exhausts sockets and battery.
  static const broadcastConcurrency = 6;

  /// A broadcast that has not finished by here is abandoned, so one wedged host cannot leave the
  /// screen stuck reporting "running" forever.
  static const broadcastTimeout = Duration(minutes: 10);

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  List<Server> get servers => _app.servers;

  List<Server> get onlineServers => _app.servers.where((s) => s.status == 'online').toList();

  /// Distinct non-empty group names among online hosts, sorted.
  List<String> get groups {
    final names =
        onlineServers.map((s) => s.groupName ?? '').where((g) => g.isNotEmpty).toSet().toList()
          ..sort();
    return names;
  }

  // ── fleet summary ───────────────────────────────────────────────────────────

  int get totalCount => servers.length;
  int get onlineCount => onlineServers.length;

  /// Online hosts scoring below 50 — the ones worth looking at first.
  int get criticalCount => servers.where((s) => s.status == 'online' && s.healthScore < 50).length;

  int get averageScore {
    if (servers.isEmpty) return 100;
    final total = servers.fold<int>(0, (sum, s) => sum + s.healthScore);
    return (total / servers.length).round();
  }

  // ── tabs ────────────────────────────────────────────────────────────────────

  FleetTab _activeTab = FleetTab.dashboard;

  FleetTab get activeTab => _activeTab;

  set activeTab(FleetTab value) {
    if (_activeTab == value) return;
    _activeTab = value;
    notifyListeners();
  }

  // ── broadcast targets ───────────────────────────────────────────────────────

  FleetTargetMode _targetMode = FleetTargetMode.servers;

  FleetTargetMode get targetMode => _targetMode;

  set targetMode(FleetTargetMode value) {
    if (_targetMode == value) return;
    _targetMode = value;
    notifyListeners();
  }

  final Set<int> _targetServerIds = {};
  final Set<String> _targetGroups = {};

  Set<int> get targetServerIds => Set.unmodifiable(_targetServerIds);
  Set<String> get targetGroups => Set.unmodifiable(_targetGroups);

  void toggleTargetServer(int id) {
    _targetServerIds.contains(id) ? _targetServerIds.remove(id) : _targetServerIds.add(id);
    notifyListeners();
  }

  void toggleTargetGroup(String group) {
    _targetGroups.contains(group) ? _targetGroups.remove(group) : _targetGroups.add(group);
    notifyListeners();
  }

  void selectAllTargets() {
    _targetServerIds
      ..clear()
      ..addAll(onlineServers.map((s) => s.id));
    notifyListeners();
  }

  void clearTargets() {
    _targetServerIds.clear();
    _targetGroups.clear();
    notifyListeners();
  }

  /// The hosts a broadcast would run on right now.
  ///
  /// Group mode resolves to *currently online* members, so a group is never a promise about hosts
  /// that cannot answer.
  List<Server> get resolvedTargets => switch (_targetMode) {
    FleetTargetMode.servers => servers.where((s) => _targetServerIds.contains(s.id)).toList(),
    FleetTargetMode.groups =>
      onlineServers.where((s) => _targetGroups.contains(s.groupName ?? '')).toList(),
  };

  /// Drops selections for hosts and groups that are no longer online.
  ///
  /// Without this, a host that went offline while it was ticked would stay silently selected and be
  /// counted as a target — the user would confirm "run on 5 hosts" and get four.
  void _pruneStaleTargets() {
    final onlineIds = onlineServers.map((s) => s.id).toSet();
    _targetServerIds.removeWhere((id) => !onlineIds.contains(id));
    _targetGroups.removeWhere((group) => !onlineServers.any((s) => (s.groupName ?? '') == group));
    _logServerIds.removeWhere((id) => !onlineIds.contains(id));
  }

  void _onAppChanged() {
    _pruneStaleTargets();
    _safeNotify();
  }

  // ── the command ─────────────────────────────────────────────────────────────

  String _commandText = '';

  String get commandText => _commandText;

  set commandText(String value) {
    if (_commandText == value) return;
    _commandText = value;
    notifyListeners();
  }

  /// A sentence naming what looks destructive about the pending command, or null.
  ///
  /// A warning, never a block: the user chose these hosts and may run what they like on them. What
  /// justifies the interruption is the multiplier — the same typo costs one host or forty.
  String? get dangerWarning => fleetCommandDangerWarning(_commandText.trim());

  bool get canRun =>
      canBroadcast && !_executing && _commandText.trim().isNotEmpty && resolvedTargets.isNotEmpty;

  // ── execution ───────────────────────────────────────────────────────────────

  bool _executing = false;
  List<BroadcastResult> _results = [];

  /// Incremented per run. A `timeout` abandons the wait but cannot cancel the workers, so they keep
  /// going; without this they would write into whatever run is current when they finally return,
  /// resurrecting a finished card as "running" or mixing one run's output into the next.
  int _runGeneration = 0;
  SshCancellationToken? _broadcastCancellation;
  int? _userCancelledGeneration;

  bool get executing => _executing;
  List<BroadcastResult> get results => List.unmodifiable(_results);

  int get successCount => _results.where((r) => r.status == BroadcastStatus.success).length;
  int get failureCount => _results.where((r) => r.status == BroadcastStatus.failure).length;

  void clearResults() {
    if (_executing) return;
    _results = [];
    notifyListeners();
  }

  /// Runs [commandText] on [targets].
  ///
  /// [targets] is passed in rather than re-resolved, because the confirmation dialog already showed
  /// the user an exact list. Re-resolving here against cached reachability — which can change
  /// between confirming and running, or simply be stale after a resume — would silently drop a host
  /// the user explicitly approved. Better to attempt it and show the real SSH error for that row.
  Future<void> runBroadcast(List<Server> targets) async {
    final command = _commandText.trim();
    final ssh = transport;
    if (command.isEmpty || _executing || targets.isEmpty) return;
    if (ssh == null) return;

    final operationId = 'fleet-${DateTime.now().microsecondsSinceEpoch}-${_operationSequence++}';
    final notifications = operationNotifications;
    if (notifications != null) {
      unawaited(
        notifications.start(
          id: operationId,
          label: 'Running command on ${targets.length} hosts',
          destination: 'fleet',
        ),
      );
    }

    final generation = ++_runGeneration;
    final cancellation = SshCancellationToken();
    _broadcastCancellation = cancellation;
    _executing = true;
    _results = [
      for (final server in targets) BroadcastResult(serverId: server.id, serverName: server.name),
    ];
    _safeNotify();

    // A simple semaphore: at most [broadcastConcurrency] hosts are in flight at once.
    final queue = List<Server>.from(targets);
    Future<void> worker(List<SshKey> keys, List<CredentialProfile> profiles) async {
      while (queue.isNotEmpty) {
        if (generation != _runGeneration) return;
        final server = queue.removeAt(0);
        final result = _results.firstWhere((r) => r.serverId == server.id);
        result.status = BroadcastStatus.running;
        _safeNotify();
        try {
          final creds = resolveCredentials(server, keys: keys, profiles: profiles);
          final output = await ssh.execStream(
            creds,
            command,
            cancellation: cancellation,
            onChunk: (chunk) async {
              if (generation != _runGeneration || cancellation.isCancelled) {
                return;
              }
              result.output.write(chunk);
              _safeNotify();
            },
          );
          if (generation != _runGeneration || cancellation.isCancelled) return;
          result.status = BroadcastStatus.success;
          // "Done (no output)" beats a blank card: a command that legitimately prints nothing is
          // otherwise indistinguishable from one whose output was lost.
          if (output.trim().isEmpty && result.output.isEmpty) {
            result.note = 'Done (no output)';
          }
        } on CredentialResolutionException catch (e) {
          result
            ..status = BroadcastStatus.failure
            ..note = e.message;
        } catch (e) {
          if (generation != _runGeneration || cancellation.isCancelled) return;
          result
            ..status = BroadcastStatus.failure
            ..note = e.toString();
        }
        if (generation != _runGeneration) return;
        _safeNotify();
      }
    }

    var timedOut = false;
    try {
      // Read inside the `try`, not before it. These are ordinary database calls, but a throw here
      // used to escape before `_executing` was ever cleared — and unlike a stranded spinner, a
      // stranded `_executing` disables Run for the rest of the session. This is the Kotlin's
      // "five stranded spinners" (§20 pattern B) in its worst form.
      final keys = await _app.repository.getAllKeys();
      final profiles = await _app.repository.getAllProfiles();
      await Future.wait([
        for (var i = 0; i < broadcastConcurrency; i++) worker(keys, profiles),
      ]).timeout(broadcastTimeout);
    } on TimeoutException {
      timedOut = true;
      cancellation.cancel();
      _markUnfinished('Timed out after ${broadcastTimeout.inMinutes} minutes.');
    } catch (e) {
      // Reported on the rows rather than swallowed: a run that never started must not look like a
      // run that finished with nothing to say.
      _markUnfinished('Could not start the run: $e');
    } finally {
      final cancelled = _userCancelledGeneration == generation;
      // Anything still pending or running after the workers returned never completed — leaving it
      // showing a spinner would misreport an abandoned run as one still in progress.
      _markUnfinished(
        cancelled ? 'Cancelled.' : 'Did not complete.',
        status: cancelled ? BroadcastStatus.cancelled : BroadcastStatus.failure,
      );
      _executing = false;
      if (identical(_broadcastCancellation, cancellation)) {
        _broadcastCancellation = null;
      }
      if (_userCancelledGeneration == generation) {
        _userCancelledGeneration = null;
      }
      // Invalidate callbacks from futures that outlive Dart's non-cancelling timeout wrapper.
      if (timedOut && _runGeneration == generation) _runGeneration++;
      await cancellation.close();
      if (notifications != null) {
        unawaited(
          notifications.finish(
            id: operationId,
            success: _results.every((result) => result.status == BroadcastStatus.success),
            cancelled: cancelled,
          ),
        );
      }
      _safeNotify();
    }
  }

  /// Stops the current fan-out without turning the user's action into a failure.
  void cancelBroadcast() {
    if (!_executing) return;
    _userCancelledGeneration = _runGeneration;
    _broadcastCancellation?.cancel();
    _safeNotify();
  }

  void _markUnfinished(String note, {BroadcastStatus status = BroadcastStatus.failure}) {
    for (final result in _results.where((r) => !r.isDone)) {
      result
        ..status = status
        ..note = result.note ?? note;
    }
  }

  // ── fleet logs ──────────────────────────────────────────────────────────────

  final Set<int> _logServerIds = {};
  List<FleetLogEntry> _logs = [];
  bool _logsLoading = false;
  String _logLevelFilter = 'ALL';

  Set<int> get logServerIds => Set.unmodifiable(_logServerIds);
  bool get logsLoading => _logsLoading;
  String get logLevelFilter => _logLevelFilter;

  set logLevelFilter(String value) {
    if (_logLevelFilter == value) return;
    _logLevelFilter = value;
    notifyListeners();
  }

  void toggleLogServer(int id) {
    _logServerIds.contains(id) ? _logServerIds.remove(id) : _logServerIds.add(id);
    notifyListeners();
  }

  /// Merged log lines, newest first, narrowed to [logLevelFilter].
  ///
  /// Merged across hosts rather than shown per host: the reason to read a fleet's logs together is
  /// to see one event's effects land on several machines in sequence.
  List<FleetLogEntry> get logs {
    final filtered = _logLevelFilter == 'ALL'
        ? _logs
        : _logs.where((l) => l.level == _logLevelFilter).toList();
    return List.unmodifiable(filtered);
  }

  Future<void> loadLogs() async {
    final ssh = transport;
    if (ssh == null || _logsLoading) return;
    final targets = onlineServers.where((s) => _logServerIds.contains(s.id)).toList();
    if (targets.isEmpty) {
      _logs = [];
      notifyListeners();
      return;
    }

    // The selection this run answers. `_logServerIds` is mutable and the user can keep tapping
    // hosts while the fetch is in flight, so the run that finishes must be able to tell whether it
    // is still answering the question that was asked.
    final requested = Set<int>.from(_logServerIds);

    _logsLoading = true;
    _safeNotify();

    try {
      final keys = await _app.repository.getAllKeys();
      final profiles = await _app.repository.getAllProfiles();
      final collected = <FleetLogEntry>[];

      await Future.wait([
        for (final server in targets)
          () async {
            try {
              final creds = resolveCredentials(server, keys: keys, profiles: profiles);
              final out = await ssh.exec(
                creds,
                journalCommand(lines: 100, os: _app.osForServer(server.id)),
              );
              collected.addAll(parseFleetJournal(out, server.name, server.id));
            } catch (_) {
              // One unreachable host must not empty the whole merged view — the point of reading a
              // fleet's logs together is the hosts that *did* answer.
            }
          }(),
      ]);

      collected.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      _logs = collected;
    } finally {
      // `finally`, because this flag also gates re-entry at the top. Left set by a throwing
      // database read it would not merely strand a spinner — it would wedge the Logs tab for the
      // rest of the session, with no way back but restarting the app.
      _logsLoading = false;
      _safeNotify();
    }

    // Answering the selection as it stands now, not as it stood when the fetch began. Publishing a
    // merged view for hosts the user has since deselected is the stale-result class that recurs
    // throughout the Kotlin history (§20 pattern A); here the honest response is simply to ask
    // again. Bounded by the user's own tapping — each pass starts from the current selection.
    if (!_disposed && !setEquals(requested, _logServerIds)) await loadLogs();
  }

  @override
  void dispose() {
    _disposed = true;
    _userCancelledGeneration = _runGeneration;
    _broadcastCancellation?.cancel();
    poller?.removeListener(_safeNotify);
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}
