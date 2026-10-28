import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/app_repository.dart';
import '../../data/remote_commands.dart';
import '../../domain/app_preferences.dart';
import '../../domain/health_scoring.dart';
import '../../domain/host_list.dart';

/// The state every feature shares: the host list, which host is selected, and the persisted app
/// settings.
///
/// This is the root of the §5.2 split. `AppViewModel.kt` is a single 12,310-line object; rather than
/// reproduce that, each feature gets its own ViewModel and they share this. Public member names are
/// kept identical to the Kotlin so the screen ports stay mechanical.
///
/// It talks to [AppRepository] and **never** to `SecretStore`: the encrypt/decrypt boundary lives in
/// exactly one place, and widening it to the presentation layer is how a password eventually gets
/// logged or written in the clear.
class AppState extends ChangeNotifier {
  AppState(this._repository);

  final AppRepository _repository;

  AppRepository get repository => _repository;

  StreamSubscription<List<Server>>? _serversSub;
  List<Server> _servers = const [];

  List<Server> get servers => _servers;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  bool _settingsLoaded = false;

  /// Whether the first authoritative preferences snapshot has replaced the in-memory defaults.
  ///
  /// Platform controllers must not act on [AppPreferences.defaults] during cold start: doing so
  /// can briefly enable a feature the user explicitly disabled before the database read finishes.
  bool get settingsLoaded => _settingsLoaded;

  int? _selectedServerId;

  /// Called when the selected host changes, so a feature holding host-scoped draft state (the
  /// Compose Builder, notably) can discard it rather than silently attributing an edit to the wrong
  /// server.
  final List<VoidCallback> onSelectedServerChanged = [];

  int? get selectedServerId => _selectedServerId;

  set selectedServerId(int? value) {
    if (value == _selectedServerId) return;
    _selectedServerId = value;
    for (final listener in onSelectedServerChanged) {
      listener();
    }
    notifyListeners();
  }

  /// The hosts that are online now.
  List<Server> get onlineServers => _servers.where((s) => s.status == 'online').toList();

  /// The selected host while it is online, else the first online host, else none: the host of a
  /// screen that needs a live connection.
  Server? get selectedOnlineServer {
    final online = _servers.where((s) => s.status == 'online');
    for (final server in online) {
      if (server.id == _selectedServerId) return server;
    }
    return online.firstOrNull;
  }

  /// The host every host-scoped screen operates on.
  ///
  /// Falls back to the first host when nothing is explicitly selected, which is what keeps the
  /// screens usable on a cold start before [start] has bound a concrete id.
  Server? get selectedServer {
    final id = _selectedServerId;
    if (id == null) return _servers.isEmpty ? null : _servers.first;
    for (final server in _servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  // ── settings ───────────────────────────────────────────────────────────────

  AppPreferences _preferences = AppPreferences.defaults;

  /// The one live preference snapshot shared by every feature.
  ///
  /// Settings previously decoded a private copy while this class decoded a smaller subset under
  /// partly different keys. That made most controls write-only. Keeping one typed snapshot means
  /// the theme, poller, terminal and transfer guards all observe the same saved values.
  AppPreferences get preferences => _preferences;

  int get metricsRetentionDays => _preferences.metricsRetentionDays;

  /// How many archived incidents to keep per host.
  int get alertHistoryLimit => _preferences.alertHistoryLimit;

  /// The health-scoring thresholds every score in the app is computed from.
  ///
  /// One copy, here, because three things read it: the telemetry poller writes a score per host per
  /// cycle, Monitor explains that score in its breakdown dialog, and Settings edits it. Two of them
  /// reading it from the database on their own schedule is how a user's edited thresholds end up
  /// applied to the score but not to the explanation of the score.
  HealthScoringConfig healthScoring = HealthScoringConfig.defaults;
  MeasurementSystem get measurementSystem => _preferences.measurementSystem;
  bool alertsEnabled = true;
  bool homelabPresetsEnabled = false;
  bool alertPresetsEnabled = false;
  bool fleetPresetsEnabled = false;

  /// The Hosts list's order, saved as `host_sort`.
  HostSort hostSort = HostSort.name;
  bool get batterySaverEnabled => _preferences.batterySaverEnabled;
  int get batterySaverThresholdPct => _preferences.batterySaverThresholdPercent;
  int get sftpLargeBatchFileThreshold => _preferences.sftpWarnFileCount;
  int get sftpLargeBatchBytesThreshold => _preferences.sftpWarnGigabytes * 1000000000;
  bool get hideSensitiveInfo => _preferences.hideSensitiveInfo;

  /// Whether the app asks the platform to keep its contents out of screenshots, recordings and the
  /// task-switcher thumbnail. Read here rather than by the Settings screen alone, because it has to
  /// be applied for the whole app, not while one screen happens to be open.
  bool get flagSecure => _preferences.blockScreenshots;

  /// Begin observing the database and load persisted settings.
  Future<void> start() async {
    await loadSettings();
    unawaited(_seedLastSeen());

    _serversSub = _repository.serversStream.listen((list) {
      _forgetGoneOrMovedHosts(_servers, list);
      _servers = list;
      // Bind a concrete host as soon as the list loads. Without this, selectedServerId stays null on
      // a cold start while selectedServer falls back to the first host — and per-tab loaders whose
      // "host changed mid-fetch" guard compares `server.id != selectedServerId` bail out, leaving
      // their spinner stuck until a host is picked by hand.
      if (_selectedServerId == null && list.isNotEmpty) {
        _selectedServerId = list.first.id;
      }
      _loaded = true;
      notifyListeners();
    });
  }

  Future<void> loadSettings() async {
    final rows = await _repository.getAllSettings();
    final values = {for (final row in rows) row.key: row.value};
    _preferences = AppPreferences.decode(values);
    healthScoring = HealthScoringConfig.decode(values[HealthScoringConfig.settingKey]);
    alertsEnabled = values['alerts_enabled'] != 'false';
    homelabPresetsEnabled = values['homelab_presets'] == 'true';
    alertPresetsEnabled = values['alert_presets'] == 'true';
    fleetPresetsEnabled = values['fleet_presets'] == 'true';
    hostSort = HostSort.fromSetting(values[HostSort.settingKey]);
    _settingsLoaded = true;
    notifyListeners();
  }

  /// Publishes a settings save without waiting for a restart or another database read.
  void applyPreferences(AppPreferences value) {
    if (_preferences == value) return;
    _preferences = value;
    notifyListeners();
  }

  /// Remote OS family per host id ("Linux" | "FreeBSD" | "Darwin" | "Windows"), as detected by the
  /// probe. Cached here rather than per screen so the Monitor, Infra and SFTP screens all pick the
  /// same command variants for a host.
  final Map<int, String> _osByServer = {};

  /// The detected OS family for [serverId], or "" when nothing has probed it yet — which the
  /// command builders resolve to Linux, the safest superset.
  String osForServer(int serverId) => _osByServer[serverId] ?? '';

  void recordOsForServer(int serverId, String os) {
    if (_osByServer[serverId] == os) return;
    _osByServer[serverId] = os;
    notifyListeners();
  }

  /// Called with a host's id when what is known about it no longer applies: the host was deleted,
  /// or its address or port changed so it may now be a different machine. Features holding per-host
  /// readings (system specs, notably) drop them, as the OS cache below does.
  final List<void Function(int serverId)> onHostForgotten = [];

  /// Called with a host's id when its current health stops being current, so whoever holds its
  /// live reading drops it, as Kotlin's `invalidateCurrentHealth` drops `hostMetricsById`.
  final List<void Function(int serverId)> onHealthInvalidated = [];

  final Map<int, int> _lastSeenAt = {};

  final Map<int, String> _metricsErrors = {};

  /// Why online [serverId] has no current metrics, when there is a reason to give; the Hosts card
  /// shows it in place of "Waiting for verified metrics…". Kotlin's `metricsErrorsById`.
  String? metricsErrorFor(int serverId) => _metricsErrors[serverId];

  /// Kotlin's `invalidateCurrentHealth`: [serverId]'s health is unknown until a fresh sample
  /// arrives, and [reason] is shown wherever its metrics would be.
  Future<void> invalidateCurrentHealth(int serverId, String reason) async {
    // A probe or poll still in flight when the app shuts down has nothing left to tell.
    if (_disposed) return;
    _metricsErrors[serverId] = reason;
    for (final listener in onHealthInvalidated.toList()) {
      listener(serverId);
    }
    notifyListeners();
    await _repository.updateHealthScore(serverId, -1);
  }

  /// Called when a sample arrives, which answers whatever was being waited for.
  void clearMetricsError(int serverId) {
    if (!_disposed && _metricsErrors.remove(serverId) != null) notifyListeners();
  }

  /// When OmniTerm last had metrics or a working SSH connection from [serverId], in epoch
  /// milliseconds, for an offline host's "Last seen" line; null when it never has. Kotlin's
  /// `lastSeenAt`: seeded from stored metrics, so it survives a restart for as long as they are kept.
  int? lastSeenAt(int serverId) => _lastSeenAt[serverId];

  /// Records that [serverId] answered at [atMs], unless a later answer is already known.
  ///
  /// Quietly: telemetry calls this for every sample of every host, and only an offline host shows
  /// the time. A host going offline rebuilds its card anyway, which then reads the latest value.
  void noteSeen(int serverId, int atMs) {
    if ((_lastSeenAt[serverId] ?? 0) < atMs) _lastSeenAt[serverId] = atMs;
  }

  Future<void> _seedLastSeen() async {
    final samples = await _repository.getLatestMetricsForAllServers();
    for (final sample in samples) {
      noteSeen(sample.serverId, sample.timestamp);
    }
    // Hosts may already be drawn as offline by now; show them their stored time.
    if (samples.isNotEmpty) notifyListeners();
  }

  /// Kotlin's `forgetTelemetryFor`, run for each host that left [next] or moved within it.
  void _forgetGoneOrMovedHosts(List<Server> previous, List<Server> next) {
    final now = {for (final s in next) s.id: s};
    for (final before in previous) {
      final after = now[before.id];
      if (after != null && after.host == before.host && after.port == before.port) continue;
      // A moved host keeps the reason it is waiting for metrics; a deleted one has nothing left.
      if (after == null) _metricsErrors.remove(before.id);
      _osByServer.remove(before.id);
      _lastSeenAt.remove(before.id);
      for (final listener in onHostForgotten) {
        listener(before.id);
      }
    }
  }

  /// The OS family of [serverId], asking the host over [exec] when nothing has probed it yet.
  ///
  /// `exec` returns `'SSH Error: …'` rather than throwing, and a cached answer is trusted for the
  /// life of the host. Caching what a failed probe normalises to would send Linux commands to that
  /// host from then on, so a failed probe answers this one call and is never cached.
  Future<String> hostOs(int serverId, Future<String> Function(String command) exec) async {
    final known = osForServer(serverId);
    if (known.isNotEmpty) return known;
    final probe = await exec(osProbeCommand);
    final os = normaliseOs(probe);
    if (!probe.startsWith('SSH Error')) recordOsForServer(serverId, os);
    return os;
  }

  /// Orders the Hosts list by [sort] at once and remembers it for next time.
  Future<void> updateHostSort(HostSort sort) async {
    hostSort = sort;
    notifyListeners();
    await _repository.insertSetting(HostSort.settingKey, sort.settingValue);
  }

  /// Persist a setting and refresh the in-memory copy.
  ///
  /// Written through the repository so a secret setting (`app_pin`) is encrypted on the way down
  /// without this class knowing which keys those are.
  Future<void> saveSetting(String key, String value) async {
    await _repository.insertSetting(key, value);
    await loadSettings();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _serversSub?.cancel();
    super.dispose();
  }
}
