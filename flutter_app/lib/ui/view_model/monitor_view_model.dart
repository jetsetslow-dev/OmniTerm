import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/remote_parsers.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/cron_schedule.dart';
import '../../domain/health_scoring.dart';
import '../../domain/measurement_units.dart';
import '../../domain/monitor_history.dart';
import '../../domain/server_credentials.dart';
import '../../domain/operation_generation.dart';
import 'app_state.dart';
import 'telemetry_poller.dart';

/// The Monitor screen's six sub-tabs, in the Kotlin's order (`ui/MonitorScreen.kt` line 100).
enum MonitorTab { overview, processes, services, logs, scripts, cron }

/// The Monitor screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Holds what Monitor needs — the host it is showing, the active tab, and each tab's loaded data —
/// and reads the host list from the shared [AppState] rather than keeping a second copy.
class MonitorViewModel extends ChangeNotifier {
  MonitorViewModel(this._app, {this.transport, this.poller}) {
    _app.addListener(_onAppChanged);
    poller?.addListener(_onTelemetrySample);
  }

  final AppState _app;

  /// The fleet-wide telemetry loop, when one is running.
  ///
  /// Monitor does not poll for itself: this screen showing live numbers while every other screen
  /// showed stale ones is how the two disagree. It adopts the poller's sample for whichever host it
  /// is showing, and keeps [loadHostMetrics] for the manual refresh and for builds with no poller.
  final TelemetryPoller? poller;

  /// When the next telemetry cycle is due, for the countdown. Null without a poller.
  DateTime? get nextRefreshAt => poller?.nextCycleAt;

  /// When the sample **on screen** was taken, whichever loop fetched it.
  ///
  /// Not simply the poller's timestamp: Monitor fetches once itself when Overview opens, and for
  /// the first fifteen seconds that is the reading being displayed. Reporting "waiting for the
  /// first sample" beside a screen full of real numbers — which is what a device run showed — tells
  /// the user the figures are not to be trusted when they are.
  DateTime? get metricsSampledAt {
    final server = monitoredServer;
    final polled = server == null ? null : poller?.sampledAtFor(server.id);
    if (polled == null) return _metricsAt;
    if (_metricsAt == null) return polled;
    return polled.isAfter(_metricsAt!) ? polled : _metricsAt;
  }

  DateTime? _metricsAt;

  /// The recent CPU readings for the monitored host, oldest first, for the Overview chart.
  ///
  /// Empty without a poller: a chart is a claim about how something changed over time, and one
  /// on-demand fetch cannot support it.
  List<double> get cpuHistory => _history.map((s) => s.metrics.cpuPercent).toList();

  /// The recent memory readings, parallel to [cpuHistory].
  List<double> get ramHistory => _history.map((s) => s.metrics.memPercent).toList();

  /// When each of those readings was taken, for the chart's end labels.
  List<int> get historyTimestamps => _history.map((s) => s.at.millisecondsSinceEpoch).toList();

  List<TimedSample> get _history {
    final server = monitoredServer;
    return server == null ? const [] : poller?.historyForServer(server.id) ?? const [];
  }

  // ── retained history ────────────────────────────────────────────────────────
  //
  // The charts above are the poller's in-memory samples: minutes of detail, gone on restart. This
  // is the persisted series behind Kotlin's "7-DAY HISTORY" card — the same rows the telemetry
  // poller writes and the pruning setting trims.

  /// The unit system every temperature on this screen is shown in.
  MeasurementSystem get measurementSystem => _app.measurementSystem;

  /// Retained telemetry for the monitored host, condensed to one point per clock hour.
  ///
  /// Null until the first load, which is what lets the card stay absent rather than flashing an
  /// empty chart while the query runs.
  HourlyMetricSeries? get hourlySeries => _hourlySeries;
  HourlyMetricSeries? _hourlySeries;

  int _hourlyForServer = -1;

  /// How far back the retained card looks, matching the card's title.
  static const retainedHistoryWindow = Duration(days: 7);

  /// Loads the retained series for the monitored host.
  ///
  /// Re-reads when the monitored host changes, because the previous host's history under this
  /// host's name would be a straightforwardly false chart.
  Future<void> loadHourlySeries({bool force = false}) async {
    final server = monitoredServer;
    if (server == null) {
      if (_hourlySeries != null) {
        _hourlySeries = null;
        _hourlyForServer = -1;
        _safeNotify();
      }
      return;
    }
    if (!force && _hourlyForServer == server.id) return;
    _hourlyForServer = server.id;
    final since = DateTime.now()
        .subtract(retainedHistoryWindow)
        .millisecondsSinceEpoch;
    final rows = await _app.repository.getMetricsSince(server.id, since);
    // The host can change while the query is in flight.
    if (_disposed || monitoredServer?.id != server.id) return;
    _hourlySeries = buildHourlyMetricSeries(rows);
    _safeNotify();
  }

  /// Why the monitored host scores what it does.
  ///
  /// Computed from the same config the poller scored with (held on [AppState]) and the readings on
  /// screen, so the explanation cannot disagree with the number it explains.
  HealthBreakdown? get healthBreakdown {
    final server = monitoredServer;
    if (server == null) return null;
    return _app.healthScoring.breakdown(
      _metrics.cpuPercent,
      _metrics.memPercent,
      _metrics.diskPercent,
      server.lastLatency,
      online: server.status == 'online',
    );
  }

  void _onTelemetrySample() {
    final server = monitoredServer;
    if (server == null) return;
    final sample = poller?.metricsForServer(server.id);
    // The poller notifies at the start and end of every cycle too; only a real sample replaces what
    // is on screen.
    if (sample == null) return;
    _metrics = sample;
    _metricsAt = poller?.sampledAtFor(server.id);
    _safeNotify();
  }

  /// Null in tests and in any build without a transport wired; every loader then reports that
  /// monitoring is unavailable rather than showing an empty tab that looks like a healthy host with
  /// nothing running.
  final SshTransport? transport;

  bool get canMonitor => transport != null;

  /// Set by [dispose]. A fetch already in flight when the user leaves Monitor will still complete,
  /// and notifying a disposed [ChangeNotifier] throws — so every post-await notification is routed
  /// through [_safeNotify]. Leaving the screen mid-load is ordinary use, not an edge case.
  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ── which host is being monitored ───────────────────────────────────────────

  /// The host Monitor shows: the explicitly selected one **if it is still online**, otherwise the
  /// first online host, otherwise none.
  ///
  /// The Kotlin used the selection unconditionally (`explicitlySelected ?: onlineServers.first`),
  /// which left Monitor rendering a host that had since gone offline while the online-only selector
  /// bar above it no longer listed that host — so the header disagreed with the body and there was
  /// no way to switch away from it. Every tab also kept issuing SSH commands at a host that was
  /// down. See MIGRATION.md §15.4.
  Server? get monitoredServer {
    final online = _app.servers.where((s) => s.status == 'online');
    final selectedId = _app.selectedServerId;
    for (final server in online) {
      if (server.id == selectedId) return server;
    }
    return online.firstOrNull;
  }

  /// The hosts the picker can offer. Only online ones: an SSH command to a host that is down can
  /// only ever time out, and offering it invites the user to blame the app.
  List<Server> get onlineServers => _app.servers.where((s) => s.status == 'online').toList();

  /// True when there is nothing to monitor, so the screen shows its empty state.
  bool get hasNoOnlineHosts => monitoredServer == null;

  /// Switches the monitored host. Goes through [AppState] so the rest of the app follows along,
  /// rather than Monitor holding a private selection that disagrees with every other screen.
  void selectServer(int? id) => _app.selectedServerId = id;

  int? _lastServerId;

  void _onAppChanged() {
    final current = monitoredServer?.id;
    if (current != _lastServerId) {
      _lastServerId = current;
      // Another host's processes, services and logs are not this host's. Showing them while the new
      // fetch is in flight would attribute one machine's state to another.
      _clearHostScopedData();
      if (current != null) unawaited(loadActiveTab());
    }
    notifyListeners();
  }

  void _clearHostScopedData() {
    _processes = const [];
    _services = const [];
    _logs = const [];
    _logsUnsupported = false;
    _servicesUnsupported = false;
    _metrics = HostMetrics.empty;
    _metricsAt = null;
    _scriptRun = null;
    _cronLines = const [];
    _cronReadable = false;
    _cronError = null;
    _cronStatus = null;
    _expandedProcessPid = null;
    _actionFeedback = null;
    _error = null;
  }

  // ── tabs ────────────────────────────────────────────────────────────────────

  MonitorTab _activeTab = MonitorTab.overview;

  MonitorTab get activeTab => _activeTab;

  set activeTab(MonitorTab value) {
    if (_activeTab == value) return;
    _activeTab = value;
    notifyListeners();
    unawaited(loadActiveTab());
  }

  /// Loads whatever the active tab is actually showing.
  ///
  /// This is also what pull-to-refresh calls: refreshing Monitor while the Services tab is open has
  /// to fetch services, not host metrics.
  Future<void> loadActiveTab() => switch (_activeTab) {
    MonitorTab.overview => loadHostMetrics(),
    MonitorTab.processes => loadProcesses(),
    MonitorTab.services => loadServices(),
    MonitorTab.logs => loadLogs(),
    MonitorTab.cron => loadCron(),
    // Scripts are repository-backed and need no remote refresh.
    _ => Future<void>.value(),
  };

  // ── overview ────────────────────────────────────────────────────────────────

  HostMetrics _metrics = HostMetrics.empty;
  bool _metricsLoading = false;

  HostMetrics get metrics => _metrics;
  bool get metricsLoading => _metricsLoading;

  /// One round trip returning every section Overview needs.
  ///
  /// The reply also carries the host's OS family, which is cached in [AppState] so the process,
  /// service and log commands pick the right variant for this host from then on — rather than each
  /// tab probing `uname` for itself.
  Future<void> loadHostMetrics() async {
    await _load(
      operation: 'hostMetrics',
      setLoading: (v) => _metricsLoading = v,
      run: (server, exec) async {
        final out = await exec(metricsFor(_osFor(server)));
        final parsed = parseMetrics(out, host: server.host);
        return () {
          _metrics = parsed;
          _metricsAt = DateTime.now();
          if (parsed.os.isNotEmpty) {
            _app.recordOsForServer(server.id, parsed.os);
          }
        };
      },
    );
  }

  // ── loaded data ─────────────────────────────────────────────────────────────

  List<SimProcess> _processes = const [];
  List<SimService> _services = const [];
  List<SimLog> _logs = const [];

  List<SimProcess> get processes => _processes;
  List<SimService> get services => _services;
  List<SimLog> get logs => _logs;

  bool _processesLoading = false;
  bool _servicesLoading = false;
  bool _logsLoading = false;

  bool get processesLoading => _processesLoading;
  bool get servicesLoading => _servicesLoading;
  bool get logsLoading => _logsLoading;

  bool _logsUnsupported = false;
  bool _servicesUnsupported = false;

  /// True when the host has no readable log source, so the pane can say why it is empty instead of
  /// looking like a host that logs nothing.
  bool get logsUnsupported => _logsUnsupported;

  /// True when the host runs neither systemd nor OpenRC.
  bool get servicesUnsupported => _servicesUnsupported;

  String? _error;
  String? _actionFeedback;

  String? get error => _error;

  /// Transient result of a service action, dismissable by the user.
  String? get actionFeedback => _actionFeedback;

  void dismissActionFeedback() {
    _actionFeedback = null;
    notifyListeners();
  }

  // ── processes ───────────────────────────────────────────────────────────────

  bool _sortByCpu = true;

  bool get sortByCpu => _sortByCpu;

  set sortByCpu(bool value) {
    if (_sortByCpu == value) return;
    _sortByCpu = value;
    // Re-sorting what is already loaded is instant; the Kotlin re-fetched from the host, which
    // meant a sort toggle waited on a round trip to show a list it already had.
    _processes = sortProcesses(_processes, byCpu: value);
    notifyListeners();
  }

  int? _expandedProcessPid;

  int? get expandedProcessPid => _expandedProcessPid;

  void toggleProcessExpanded(int pid) {
    _expandedProcessPid = _expandedProcessPid == pid ? null : pid;
    notifyListeners();
  }

  /// Orders processes by the heaviest consumer of the chosen resource.
  static List<SimProcess> sortProcesses(List<SimProcess> list, {required bool byCpu}) {
    final sorted = [...list];
    sorted.sort((a, b) => byCpu ? b.cpu.compareTo(a.cpu) : b.mem.compareTo(a.mem));
    return sorted;
  }

  Future<void> loadProcesses() async {
    await _load(
      operation: 'processes',
      setLoading: (v) => _processesLoading = v,
      run: (server, exec) async {
        final out = await exec(processesFor(_osFor(server)));
        final parsed = sortProcesses(parseProcesses(out), byCpu: _sortByCpu);
        return () => _processes = parsed;
      },
    );
  }

  Future<void> killProcess(int pid, {int signal = 15}) async {
    await _load(
      operation: 'killProcess',
      setLoading: (_) {},
      run: (server, exec) async {
        final out = (await exec(killProcessCommand(pid, signal: signal))).trim();
        return () => _actionFeedback = out;
      },
    );
    await loadProcesses();
  }

  // ── services ────────────────────────────────────────────────────────────────

  Future<void> loadServices() async {
    await _load(
      operation: 'services',
      setLoading: (v) => _servicesLoading = v,
      run: (server, exec) async {
        final out = await exec(servicesCommand);
        final unsupported = out.contains('---NOSYSTEMD---');
        final parsed = parseServices(out);
        return () {
          _servicesUnsupported = unsupported;
          _services = parsed;
        };
      },
    );
  }

  /// Runs start / stop / restart / enable / disable against [service].
  ///
  /// The sudo password travels via stdin, never in the command string — see [sudoStdin].
  Future<void> runServiceAction(SimService service, String action) async {
    // Keyed per service and action: two actions on different services are genuinely independent,
    // and keying them together would let one silently discard the other's result.
    await _load(
      operation: 'serviceAction:${service.name}:$action',
      setLoading: (v) => _servicesLoading = v,
      run: (server, exec) async {
        final password = server.sudoPassword;
        final out = await exec(
          serviceAction(service.name, action, sudoPassword: password),
          stdin: sudoStdin(password),
        );
        final trimmed = out.trim();
        return () => _actionFeedback = trimmed.isEmpty ? '$action ${service.name}: done' : trimmed;
      },
    );
    await loadServices();
  }

  // ── logs ────────────────────────────────────────────────────────────────────

  static const logFilters = ['ALL', 'INFO', 'WARN', 'ERROR'];

  String _logFilter = 'ALL';

  String get logFilter => _logFilter;

  set logFilter(String value) {
    if (_logFilter == value) return;
    _logFilter = value;
    // The filter is applied locally to what was already fetched, so switching it is instant.
    notifyListeners();
  }

  /// The loaded log lines narrowed to [logFilter].
  List<SimLog> get filteredLogs =>
      _logFilter == 'ALL' ? _logs : _logs.where((l) => l.level == _logFilter).toList();

  bool _logsLive = false;

  bool get logsLive => _logsLive;

  set logsLive(bool value) {
    if (_logsLive == value) return;
    _logsLive = value;
    notifyListeners();
    if (value) {
      _liveTimer = Timer.periodic(logsLiveInterval, (_) => unawaited(loadLogs()));
    } else {
      _liveTimer?.cancel();
      _liveTimer = null;
    }
  }

  static const logsLiveInterval = Duration(seconds: 5);
  Timer? _liveTimer;

  Future<void> loadLogs() async {
    await _load(
      operation: 'logs',
      setLoading: (v) => _logsLoading = v,
      run: (server, exec) async {
        final out = await exec(journalCommand(os: _osFor(server)));
        final unsupported = journalUnsupported(out);
        final parsed = parseJournal(out);
        return () {
          _logsUnsupported = unsupported;
          _logs = parsed;
        };
      },
    );
  }

  // ── quick scripts ───────────────────────────────────────────────────────────

  /// The command currently running from the Scripts tab, and everything it has printed.
  ///
  /// Held on the view model rather than in the tab's widget state so leaving the tab — or the
  /// screen — does not throw away output from a command that is still running on someone's server.
  ScriptRun? _scriptRun;

  ScriptRun? get scriptRun => _scriptRun;

  void clearScriptRun() {
    _scriptRun = null;
    notifyListeners();
  }

  /// Runs [command] on the monitored host, streaming its output.
  ///
  /// Streamed rather than awaited whole: a quick script is often something slow — a package update,
  /// a backup — and a screen that shows nothing until it finishes is indistinguishable from one
  /// that has hung.
  Future<void> runScript(String title, String command) async {
    final server = monitoredServer;
    final ssh = transport;
    if (server == null) return;

    final run = ScriptRun(title: title, command: command, serverId: server.id);
    _scriptRun = run;
    _safeNotify();

    if (ssh == null) {
      run
        ..finished = true
        ..error = 'Running commands is unavailable in this build.';
      _safeNotify();
      return;
    }

    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      await ssh.execStream(
        creds,
        command,
        onChunk: (chunk) async {
          // A run the user dismissed, or one replaced by a newer run, must not keep writing to the
          // panel — its output would appear under another command's heading.
          if (_scriptRun != run) return;
          run.output.write(chunk);
          _safeNotify();
        },
      );
    } on CredentialResolutionException catch (e) {
      run.error = e.message;
    } catch (e) {
      run.error = e.toString();
    } finally {
      run.finished = true;
      if (_scriptRun == run) _safeNotify();
    }
  }

  // ── cron ────────────────────────────────────────────────────────────────────

  List<CronLine> _cronLines = const [];
  bool _cronLoading = false;
  bool _cronReadable = false;
  String? _cronError;
  String? _cronStatus;

  List<CronLine> get cronLines => _cronLines;
  bool get cronLoading => _cronLoading;

  /// True once a crontab has actually been read from this host.
  ///
  /// **Editing is gated on this.** Saving replaces the user's whole crontab, so offering Add or
  /// Delete after a read that failed would let the app write a file built from an error message —
  /// see [crontabReadCommand] for what the Kotlin does instead.
  bool get cronReadable => _cronReadable;

  /// Why the crontab could not be read, verbatim from the host.
  String? get cronError => _cronError;

  /// The result of the last save, for the screen to show.
  String? get cronStatus => _cronStatus;

  void dismissCronStatus() {
    _cronStatus = null;
    notifyListeners();
  }

  Future<void> loadCron() async {
    _cronStatus = null;
    await _load(
      operation: 'cron',
      setLoading: (v) => _cronLoading = v,
      run: (server, exec) async {
        final read = parseCrontabRead(await exec(crontabReadCommand));
        final parsed = parseCrontab(read.text);
        return () {
          _cronReadable = read.readable;
          _cronError = read.readable ? null : read.error;
          _cronLines = read.readable ? parsed : const [];
        };
      },
    );
  }

  /// Writes [lines] back as the host user's crontab, then re-reads to confirm.
  ///
  /// Confirmed by reading, not by an empty reply: `crontab -` prints an installation notice on some
  /// implementations and nothing at all on others, so treating any output as failure — which the
  /// Kotlin does — reports a save that worked as an error, and the user's next move is to try again.
  Future<void> saveCron(List<CronLine> lines) async {
    if (!_cronReadable) return;
    final wanted = renderCrontab(lines);

    await _load(
      operation: 'cron',
      setLoading: (v) => _cronLoading = v,
      run: (server, exec) async {
        await exec(crontabWriteCommand(wanted));
        final read = parseCrontabRead(await exec(crontabReadCommand));
        final landed = renderCrontab(parseCrontab(read.text));
        return () {
          if (!read.readable) {
            _cronStatus = 'Saved, but the crontab could not be read back to confirm it.';
            return;
          }
          _cronLines = parseCrontab(read.text);
          // Compared against what the host now has rather than what was sent: cron rewrites what it
          // accepts, and a silent rejection would otherwise be reported as success.
          _cronStatus = landed.trim() == wanted.trim()
              ? 'Crontab saved.'
              : 'The host stored something different from what was sent — check the entries below.';
        };
      },
    );
  }

  // ── reboot ──────────────────────────────────────────────────────────────────

  /// Reboots the monitored host. The caller is responsible for confirming first — this does not ask.
  Future<void> rebootMonitoredHost() async {
    await _load(
      operation: 'reboot',
      setLoading: (_) {},
      run: (server, exec) async {
        final password = server.sudoPassword;
        await exec(rebootCommand(sudoPassword: password), stdin: sudoStdin(password));
        return () => _actionFeedback = '${server.name} is rebooting.';
      },
    );
  }

  // ── shared loader plumbing ──────────────────────────────────────────────────

  /// Remote OS family, cached by the telemetry poller. Empty resolves to Linux, the safest superset.
  String _osFor(Server server) => _app.osForServer(server.id);

  /// Runs [run] against the monitored host, handling loading flags and errors.
  ///
  /// [run] must not mutate state directly: it returns a closure that applies the result, which
  /// [_load] calls only if the user is still looking at the same host. A reply that arrives after
  /// the user switched hosts would otherwise attribute one machine's processes to another.
  /// Latest-wins per load, so a slow refresh cannot land after the one that replaced it.
  ///
  /// The host check below is not enough on its own: two loads of the *same* tab on the *same* host
  /// interleave routinely — the live timer fires while a manual refresh is still in flight — and
  /// both pass an identity check. This is the Kotlin's own `OperationGeneration`, which the port
  /// carried across and, until now, never called.
  final _generations = OperationGeneration<String>();

  Future<void> _load({
    required String operation,
    required void Function(bool) setLoading,
    required Future<void Function()> Function(
      Server server,
      Future<String> Function(String command, {String? stdin}) exec,
    )
    run,
  }) async {
    final server = monitoredServer;
    final ssh = transport;
    if (server == null) return;
    if (ssh == null) {
      _error = 'Monitoring is unavailable in this build.';
      _safeNotify();
      return;
    }

    setLoading(true);
    _error = null;
    _safeNotify();

    final startedFor = server.id;
    final generation = _generations.begin([operation])[operation]!;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final commit = await run(
        server,
        (command, {String? stdin}) => ssh.exec(creds, command, stdin: stdin),
      );
      if (monitoredServer?.id == startedFor) {
        _generations.publishIfCurrent(operation, generation, commit);
      }
    } on CredentialResolutionException catch (e) {
      if (_generations.isCurrent(operation, generation)) _error = e.message;
    } catch (e) {
      if (_generations.isCurrent(operation, generation)) _error = e.toString();
    } finally {
      // A superseded run must not clear the spinner belonging to the one that replaced it, or the
      // screen reports "done" while work is still running.
      if (_generations.isCurrent(operation, generation)) {
        setLoading(false);
        _safeNotify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _liveTimer?.cancel();
    poller?.removeListener(_onTelemetrySample);
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}

/// One command run from the Scripts tab, and what it has printed so far.
class ScriptRun {
  ScriptRun({required this.title, required this.command, required this.serverId});

  final String title;
  final String command;
  final int serverId;

  final StringBuffer output = StringBuffer();

  /// True once the command ended, however it ended.
  bool finished = false;

  /// Set when the run could not start or died. Kept separate from [output] so a failure is not
  /// mistaken for something the command printed.
  String? error;
}
