import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/remote_parsers.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/server_credentials.dart';
import '../../domain/operation_generation.dart';
import 'app_state.dart';

/// The Monitor screen's six sub-tabs, in the Kotlin's order (`ui/MonitorScreen.kt` line 100).
enum MonitorTab { overview, processes, services, logs, scripts, cron }

/// The Monitor screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Holds what Monitor needs — the host it is showing, the active tab, and each tab's loaded data —
/// and reads the host list from the shared [AppState] rather than keeping a second copy.
class MonitorViewModel extends ChangeNotifier {
  MonitorViewModel(this._app, {this.transport}) {
    _app.addListener(_onAppChanged);
  }

  final AppState _app;

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
    // Scripts and Cron are not ported yet (§18).
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
          if (parsed.os.isNotEmpty) _app.recordOsForServer(server.id, parsed.os);
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
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}
