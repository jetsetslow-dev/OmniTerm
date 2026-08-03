import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/app_repository.dart';
import '../../domain/measurement_units.dart';

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

  int metricsRetentionDays = 7;
  MeasurementSystem measurementSystem = MeasurementSystem.metric;
  bool alertsEnabled = true;
  bool homelabPresetsEnabled = false;
  bool alertPresetsEnabled = false;
  bool fleetPresetsEnabled = false;
  bool batterySaverEnabled = false;
  int batterySaverThresholdPct = 20;
  int sftpLargeBatchFileThreshold = 50;
  int sftpLargeBatchBytesThreshold = 1000000000;
  bool hideSensitiveInfo = false;

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
      notifyListeners();
    });
  }

  Future<void> loadSettings() async {
    Future<String?> read(String key) => _repository.getSetting(key);

    metricsRetentionDays = int.tryParse(await read('metrics_retention_days') ?? '') ?? 7;
    measurementSystem = MeasurementSystem.fromSetting(await read('measurement_system'));
    alertsEnabled = (await read('alerts_enabled')) != 'false';
    homelabPresetsEnabled = (await read('homelab_presets')) == 'true';
    alertPresetsEnabled = (await read('alert_presets')) == 'true';
    fleetPresetsEnabled = (await read('fleet_presets')) == 'true';
    batterySaverEnabled = (await read('battery_saver_enabled')) == 'true';
    batterySaverThresholdPct = int.tryParse(await read('battery_saver_threshold') ?? '') ?? 20;
    sftpLargeBatchFileThreshold =
        int.tryParse(await read('sftp_large_batch_files') ?? '') ?? 50;
    sftpLargeBatchBytesThreshold =
        int.tryParse(await read('sftp_large_batch_bytes') ?? '') ?? 1000000000;
    hideSensitiveInfo = (await read('hide_sensitive_info')) == 'true';
    notifyListeners();
  }

  /// Persist a setting and refresh the in-memory copy.
  ///
  /// Written through the repository so a secret setting (`app_pin`) is encrypted on the way down
  /// without this class knowing which keys those are.
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
