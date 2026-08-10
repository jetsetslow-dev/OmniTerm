import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/app_repository.dart';
import '../../domain/app_preferences.dart';
import '../../domain/health_scoring.dart';

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

    _serversSub = _repository.serversStream.listen((list) {
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
    notifyListeners();
  }

  /// Publishes a settings save without waiting for a restart or another database read.
  void applyPreferences(AppPreferences value) {
    if (_preferences == value) return;
    _preferences = value;
    notifyListeners();
  }

  /// Persist a setting and refresh the in-memory copy.
  ///
  /// Written through the repository so a secret setting (`app_pin`) is encrypted on the way down
  /// without this class knowing which keys those are.
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

  Future<void> saveSetting(String key, String value) async {
    await _repository.insertSetting(key, value);
    await loadSettings();
  }

  @override
  void dispose() {
    _serversSub?.cancel();
    super.dispose();
  }
}
