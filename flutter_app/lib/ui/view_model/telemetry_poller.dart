import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/remote_parsers.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/ssh_failure.dart';
import '../../domain/server_credentials.dart';
import '../../domain/telemetry_sampling.dart';
import 'app_state.dart';

/// Polls every reachable host for metrics on a fixed cadence, ported from `startTelemetryPolling`
/// and `probeServerInner` in `ui/AppViewModel.kt`.
///
/// This is what makes the app's numbers *live*. Without it Monitor only knows what it fetched when
/// its Overview tab happened to open, no host has a real health score (every one sits at the 100 it
/// was inserted with), the CPU figure is whatever `top` said in its first sampling window rather
/// than a measured rate, and nothing is ever written to the metrics history the charts read.
///
/// Split from [HostStatusProbe] on purpose. That one answers "can I reach the SSH port", cheaply,
/// for every saved host including the ones that are down. This one authenticates and runs a command,
/// so it visits **only hosts already believed to be online** — asking a host that is down for its
/// metrics can only ever time out, once per host per cycle, forever.
class TelemetryPoller extends ChangeNotifier {
  TelemetryPoller(
    this._app, {
    this.transport,
    Duration? interval,
    this.onSample,
    DateTime Function()? clock,
  }) : _intervalOverride = interval,
       _clock = clock ?? DateTime.now {
    _lastConfiguredInterval = effectiveInterval;
    _app.addListener(_onAppChanged);
  }

  final AppState _app;

  /// Null in tests and in any build without SSH wired. The poller then does nothing at all rather
  /// than pretending: [canPoll] is false and the screens say why instead of showing stale numbers
  /// that look live.
  final SshTransport? transport;

  final Duration? _intervalOverride;

  /// Tests can pin a cadence; production follows the live Settings value.
  Duration get effectiveInterval =>
      _intervalOverride ?? Duration(seconds: _app.preferences.telemetryIntervalSeconds);

  Duration? _lastConfiguredInterval;

  void _onAppChanged() {
    if (_intervalOverride != null || _timer == null || _disposed) return;
    final next = effectiveInterval;
    if (next == _lastConfiguredInterval) return;
    _lastConfiguredInterval = next;
    _timer?.cancel();
    _timer = Timer.periodic(next, (_) => unawaited(cycle()));
    _safeNotify();
  }

  /// Called with every sample this poller takes, before it returns.
  ///
  /// A callback rather than a dependency on the alerts layer: this class's job is to measure hosts,
  /// and something has to decide what a measurement *means*. Awaited, so a slow evaluation delays
  /// the next host rather than racing the sample after it; failures are the caller's to handle,
  /// because a poller that swallowed them would hide the fact that no alert is being evaluated.
  final Future<void> Function(Server server, HostMetrics metrics)? onSample;

  final DateTime Function() _clock;

  bool get canPoll => transport != null;

  Timer? _timer;
  bool _disposed = false;

  // ── what the screens read ──────────────────────────────────────────────────

  final Map<int, HostMetrics> _metrics = {};
  final Map<int, TelemetryBaseline> _baselines = {};
  final Map<int, List<TimedSample>> _history = {};

  /// The most recent sample for [serverId], or null when this host has not been polled yet.
  ///
  /// Null rather than [HostMetrics.empty]: a host nobody has asked yet is not a host running at
  /// zero, and a screen that cannot tell the two apart will draw an idle machine.
  HostMetrics? metricsForServer(int serverId) => _metrics[serverId];

  /// The recent samples for [serverId], oldest first, for the sparklines.
  List<TimedSample> historyForServer(int serverId) => _history[serverId] ?? const [];

  /// When [serverId]'s newest sample was taken, so a screen can say how old its numbers are rather
  /// than presenting a reading from four minutes ago as the current state of the machine.
  DateTime? sampledAtFor(int serverId) => _history[serverId]?.lastOrNull?.at;

  /// How many samples are kept in memory per host. Thirty at 15s is the last seven and a half
  /// minutes, which is what a sparkline can show without becoming a smear; anything longer is the
  /// persisted history's job.
  static const historyLength = 30;

  /// At most this many hosts are probed at once — the same bound [HostStatusProbe] uses, for the
  /// same reason: a phone with a fleet of fifty hosts must not open fifty SSH sessions.
  static const maxConcurrent = 4;

  DateTime? _lastCycleStart;

  /// When the most recent cycle began, so the UI can show a countdown that stays in step with the
  /// poller rather than running its own timer that drifts away from it.
  DateTime? get lastCycleStart => _lastCycleStart;

  /// When the next cycle is due, or null before the first has run.
  DateTime? get nextCycleAt => _lastCycleStart?.add(effectiveInterval);

  bool _cycling = false;
  int _workGeneration = 0;
  int _cycleRunId = 0;

  /// True while a cycle is in flight, for the refresh indicator.
  bool get isCycling => _cycling;

  // ── the loop ───────────────────────────────────────────────────────────────

  /// Poll now, then keep polling at [effectiveInterval].
  void start() {
    if (!canPoll) return;
    _workGeneration++;
    _cycleRunId++;
    _cycling = false;
    _timer?.cancel();
    unawaited(cycle());
    final cadence = effectiveInterval;
    _lastConfiguredInterval = cadence;
    _timer = Timer.periodic(cadence, (_) => unawaited(cycle()));
  }

  void stop() {
    _workGeneration++;
    _cycleRunId++;
    final wasCycling = _cycling;
    _cycling = false;
    _timer?.cancel();
    _timer = null;
    if (wasCycling) _safeNotify();
  }

  /// One pass over every online host.
  Future<void> cycle() async {
    // A cycle that is still running when the next tick arrives skips that tick rather than
    // doubling up: two cycles in flight would probe the same host twice at once and each would
    // measure its rates against the other's baseline.
    if (_cycling || _disposed || !canPoll) return;
    final generation = _workGeneration;
    final runId = ++_cycleRunId;
    _cycling = true;
    _lastCycleStart = _clock();
    _safeNotify();

    try {
      final servers = _app.servers.where((s) => s.status == 'online').toList();
      _forgetVanishedHosts();
      if (servers.isEmpty || !_workIsCurrent(generation)) return;

      final queue = servers.iterator;
      Future<void> worker() async {
        while (_workIsCurrent(generation) && queue.moveNext()) {
          await pollOne(queue.current, workGeneration: generation);
        }
      }

      await Future.wait(
        List.generate(
          servers.length < maxConcurrent ? servers.length : maxConcurrent,
          (_) => worker(),
        ),
      );
      if (_workIsCurrent(generation)) await _pruneHistory();
    } catch (_) {
      // A cycle that fails wholesale must not stop the next one. The screens keep the last sample
      // they were given, which is honest as long as nothing claims it is current — the countdown
      // above them is what says when it was taken.
    } finally {
      if (runId == _cycleRunId) {
        _cycling = false;
        _safeNotify();
      }
    }
  }

  /// Drops the per-host state of hosts that no longer exist.
  ///
  /// Without this, deleting a host leaves its counters, samples and history in memory for the life
  /// of the process, and a **new host that reuses the freed row id inherits them** — its first
  /// sample would be measured against a machine it has never met.
  void _forgetVanishedHosts() {
    final live = _app.servers.map((s) => s.id).toSet();
    _metrics.removeWhere((id, _) => !live.contains(id));
    _baselines.removeWhere((id, _) => !live.contains(id));
    _history.removeWhere((id, _) => !live.contains(id));
  }

  bool _workIsCurrent(int generation) => !_disposed && generation == _workGeneration;

  /// Polls one host and returns a user-facing failure for an explicit/manual caller.
  ///
  /// Background cycles intentionally ignore the return value so one host cannot stop the fleet,
  /// while buttons can surface the same failure instead of completing as if refresh succeeded.
  Future<String?> pollOne(Server server, {int? workGeneration}) async {
    final ssh = transport;
    if (ssh == null) return 'SSH is unavailable in this build.';
    final generation = workGeneration ?? _workGeneration;
    if (!_workIsCurrent(generation)) return null;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      if (!_workIsCurrent(generation)) return null;

      // The OS decides which metrics command to send, and sending the wrong one produces output the
      // parser reads as a host with no memory and no disks. Probed once per host and cached in
      // AppState, where Monitor, Infra and SFTP read it too.
      var os = _app.osForServer(server.id);
      if (os.isEmpty) {
        final probe = await ssh.exec(creds, osProbeCommand);
        if (!_workIsCurrent(generation)) return null;
        os = normaliseOs(probe);
        // `exec` returns `'SSH Error: …'` rather than throwing, and the cache is consulted once per
        // host and then trusted forever. Caching what a failed probe normalises to would send the
        // wrong metrics command for the life of the host — exactly the "no memory and no disks"
        // reading described above, from one transient failure. Compose guards the same way at
        // `ui/AppViewModel.kt:2404`.
        if (!probe.startsWith('SSH Error')) {
          _app.recordOsForServer(server.id, os);
        }
      }

      final raw = await ssh.exec(creds, metricsFor(os));
      if (!_workIsCurrent(generation)) return null;
      // A failed probe is not a reading. Parsing it yields a plausible-looking sample — the OS
      // defaults to Linux and every gauge to zero — which is then written to history, charted, and
      // fed back into the OS cache as if the host had answered. Compose branches on the same prefix
      // (`ui/AppViewModel.kt:2408`) and records the failure instead of a sample.
      if (raw.startsWith('SSH Error')) {
        // The Hosts list already renders `authStatus == 'failed'` — a warning row, an amber badge
        // and the words "authentication failed". Nothing in this port ever wrote the column, so a
        // host with a wrong key looked identical to a healthy one no matter how often it failed.
        // `serversStream` is a drift watch, so the write reaches AppState on its own.
        final failure = describeSshFailure(raw);
        await _app.repository.updateAuthState(server.id, 'failed', failure);
        return failure;
      }

      final now = _clock();
      final sample = enrichMetrics(
        parsed: parseMetrics(raw, host: server.host),
        raw: raw,
        nowMs: now.millisecondsSinceEpoch,
        previous: _baselines[server.id],
      );

      // The host may have been deleted while this probe was in flight. Writing now would recreate
      // rows for a host the user removed.
      if (!_workIsCurrent(generation) || !_app.servers.any((s) => s.id == server.id)) {
        return null;
      }

      _metrics[server.id] = sample.metrics;
      if (sample.baseline != null) _baselines[server.id] = sample.baseline!;
      _recordHistory(server.id, sample.metrics, now);
      if (sample.metrics.os.isNotEmpty) {
        _app.recordOsForServer(server.id, sample.metrics.os);
      }

      // A host that answered is authenticated, whatever it said last time. Written every cycle
      // rather than only when `server.authStatus` looks stale: that field is a snapshot taken when
      // the cycle began, and a row corrected in the database while it was in flight would keep an
      // old `failed` forever. The poller already writes metrics and a history row here, so one
      // more small update is proportionate.
      await _app.repository.updateAuthState(server.id, 'ok', null);
      if (!_workIsCurrent(generation)) return null;

      await _persist(server, sample.metrics, now, generation);
      if (!_workIsCurrent(generation)) return null;
      _safeNotify();
      await onSample?.call(server, sample.metrics);
      return null;
    } catch (error) {
      // One unreachable or unauthenticated host must not end the cycle for the rest of the fleet.
      // Its status is [HostStatusProbe]'s to write, not this poller's: a metrics command that fails
      // says nothing certain about reachability, and marking the host offline from here would fight
      // the probe that actually measured it.
      final failure = describeSshFailure(error.toString());
      await _app.repository.updateAuthState(server.id, 'failed', failure);
      return failure;
    }
  }

  void _recordHistory(int serverId, HostMetrics metrics, DateTime at) {
    final samples = [..._history[serverId] ?? const <TimedSample>[], TimedSample(at, metrics)];
    _history[serverId] = samples.length <= historyLength
        ? samples
        : samples.sublist(samples.length - historyLength);
  }

  Future<void> _persist(Server server, HostMetrics metrics, DateTime at, int generation) async {
    final health = _app.healthScoring.score(
      metrics.cpuPercent,
      metrics.memPercent,
      metrics.diskPercent,
      server.lastLatency,
    );

    await _app.repository.insertMetric(
      MetricHistoryCompanion.insert(
        serverId: server.id,
        timestamp: at.millisecondsSinceEpoch,
        cpuUsage: metrics.cpuPercent,
        ramUsage: metrics.memPercent,
        diskUsage: metrics.diskPercent,
        latency: server.lastLatency,
        // The columns are KB/s and the rates are bytes/s. The Kotlin writes 0 into both on every
        // sample, so its retained history has a network chart that can only ever be flat.
        networkIn: metrics.netRxPerSec / 1024,
        networkOut: metrics.netTxPerSec / 1024,
        cpuTemperatureC: Value(metrics.cpuTempC),
      ),
    );
    if (!_workIsCurrent(generation)) return;
    // The status stays whatever the reachability probe last wrote — this call is here for the
    // health score, which is the one column only real telemetry can fill in.
    await _app.repository.updateConnectionState(
      server.id,
      server.status,
      health,
      server.lastLatency,
    );
  }

  Future<void> _pruneHistory() async {
    final cutoff = _clock()
        .subtract(Duration(days: _app.metricsRetentionDays))
        .millisecondsSinceEpoch;
    await _app.repository.pruneMetrics(cutoff);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}

/// One sample and when it was taken, for the in-memory sparklines.
class TimedSample {
  const TimedSample(this.at, this.metrics);

  final DateTime at;
  final HostMetrics metrics;
}
