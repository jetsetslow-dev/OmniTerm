import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_models.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/host_limit.dart';
import '../../domain/health_scoring.dart';
import '../../domain/measurement_units.dart';
import '../../domain/server_credentials.dart';
import '../../platform/shortcut_helper.dart';
import 'app_state.dart';

/// The Servers screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Owns only what the Servers screen needs — search text, the group filter, multi-select — and reads
/// the host list from the shared [AppState] rather than holding a second copy that could drift.
class ServersViewModel extends ChangeNotifier {
  ServersViewModel(this._app, {this.transport, this.shortcuts}) {
    _app.addListener(notifyListeners);
  }

  final AppState _app;

  /// Null in tests and in any build without a transport wired; Test Connection is then unavailable
  /// rather than silently reporting success.
  final SshTransport? transport;
  final ShortcutHelper? shortcuts;

  bool get canTestConnections => transport != null;

  /// The Play Store free tier allows one saved host; the source-available build is unlimited.
  static const freePlayStoreLimit = 1;

  String _serverSearchText = '';
  String? _selectedGroupChip = 'All';
  bool _isMultiSelectMode = false;
  final List<int> _selectedServerIdsForBulk = [];

  List<Server> get servers => _app.servers;
  Server? get selectedServer => _app.selectedServer;
  MeasurementSystem get measurementSystem => _app.measurementSystem;
  int? get selectedServerId => _app.selectedServerId;
  set selectedServerId(int? value) => _app.selectedServerId = value;

  HealthBreakdown healthBreakdown(Server server, HostMetrics? metrics) =>
      _app.healthScoring.breakdown(
        metrics?.cpuPercent ?? 0,
        metrics?.memPercent ?? 0,
        metrics?.diskPercent ?? 0,
        server.lastLatency,
        online: server.status == 'online',
      );

  String get serverSearchText => _serverSearchText;

  set serverSearchText(String value) {
    if (_serverSearchText == value) return;
    _serverSearchText = value;
    notifyListeners();
  }

  String? get selectedGroupChip => _selectedGroupChip;

  set selectedGroupChip(String? value) {
    if (_selectedGroupChip == value) return;
    _selectedGroupChip = value;
    notifyListeners();
  }

  bool get isMultiSelectMode => _isMultiSelectMode;

  set isMultiSelectMode(bool value) {
    if (_isMultiSelectMode == value) return;
    _isMultiSelectMode = value;
    // Leaving multi-select must drop the selection; keeping it would let a later bulk action apply
    // to hosts the user can no longer see ticked.
    if (!value) _selectedServerIdsForBulk.clear();
    notifyListeners();
  }

  List<int> get selectedServerIdsForBulk =>
      List.unmodifiable(_selectedServerIdsForBulk);

  /// The aliases of every stored SSH key, for the form's key picker.
  Future<List<String>> savedKeyAliases() async =>
      (await _app.repository.getAllKeys()).map((k) => k.alias).toList();

  /// Attempts a connection with [candidate]'s settings. Returns null on success, otherwise a
  /// message to show the user.
  ///
  /// The candidate is the *unsaved* form row, so the test exercises exactly what is about to be
  /// written rather than what is currently stored.
  Future<String?> testConnection(Server candidate) async {
    final transport = this.transport;
    if (transport == null) {
      return 'Connection testing is unavailable in this build.';
    }
    try {
      final creds = resolveCredentials(
        candidate,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final failure = await transport.testConnection(creds);
      // Persisted, not just returned. Nothing else wrote this column, so a host stayed offline
      // forever no matter how many times its connection tested green — and every screen that
      // filters on `status == 'online'` showed nothing (§15.8).
      await _app.repository.updateConnectionState(
        candidate.id,
        failure == null ? 'online' : 'offline',
        candidate.healthScore,
        0,
      );
      return failure;
    } on CredentialResolutionException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  void toggleBulkSelection(int serverId) {
    if (!_selectedServerIdsForBulk.remove(serverId)) {
      _selectedServerIdsForBulk.add(serverId);
    }
    notifyListeners();
  }

  void clearBulkSelection() {
    if (_selectedServerIdsForBulk.isEmpty) return;
    _selectedServerIdsForBulk.clear();
    notifyListeners();
  }

  void selectAllServers() {
    _selectedServerIdsForBulk
      ..clear()
      ..addAll(filteredServers.map((server) => server.id));
    notifyListeners();
  }

  /// The filter chips: "All" plus every distinct group name actually in use.
  ///
  /// Derived from the live list rather than stored, so a group disappears from the bar as soon as
  /// its last host leaves it.
  List<String> get groupChips {
    final groups = <String>[];
    for (final server in servers) {
      final group = server.groupName;
      if (group != null && !groups.contains(group)) groups.add(group);
    }
    return ['All', ...groups];
  }

  /// Hosts matching the current search text and group chip.
  ///
  /// Search is case-insensitive across **name and host**, so a user who remembers the address but
  /// not the label still finds the machine.
  List<Server> get filteredServers {
    final needle = _serverSearchText.toLowerCase();
    return [
      for (final server in servers)
        if ((server.name.toLowerCase().contains(needle) ||
                server.host.toLowerCase().contains(needle)) &&
            (_selectedGroupChip == 'All' ||
                server.groupName == _selectedGroupChip))
          server,
    ];
  }

  /// True when the free-tier host limit has been reached.
  ///
  /// [unlocked] comes from the billing controller; the source-available build passes true because it
  /// carries no billing code at all.
  bool hostLimitReached({
    required bool playStoreBuild,
    required bool unlocked,
  }) => playStoreBuild && !unlocked && servers.length >= freePlayStoreLimit;

  /// True when the install already holds **more** hosts than its entitlement allows.
  ///
  /// Distinct from [hostLimitReached], which stops a *new* host being added. This is the standing
  /// violation: a restore on an older build, a lapsed unlock or a refund all leave hosts already
  /// saved, and blocking additions does nothing about those.
  bool hostLimitExceededNow({
    required bool playStoreBuild,
    required bool unlocked,
  }) => hostLimitExceeded(
    hasHostLimit: playStoreBuild && !unlocked,
    hostLimit: freePlayStoreLimit,
    hostCount: servers.length,
  );

  /// Keeps [keepIds] and deletes every other saved host.
  ///
  /// Refuses a selection that is not exactly the limit rather than doing something approximate:
  /// this deletes hosts, and a flow that deletes more than the user chose — or leaves the install
  /// still over its limit — is worse than one that declines. Returns how many were removed.
  Future<int> reconcileHostLimit(Set<int> keepIds) async {
    if (!isValidHostKeepSelection(
      selectedCount: keepIds.length,
      hostLimit: freePlayStoreLimit,
    )) {
      return 0;
    }
    final doomed = servers.where((s) => !keepIds.contains(s.id)).toList();
    for (final server in doomed) {
      await deleteServer(server.id);
    }
    return doomed.length;
  }

  // ── actions ────────────────────────────────────────────────────────────────

  Future<int> saveServer(Server server) => _app.repository.insertServer(server);

  Future<void> updateServer(Server server) async {
    await _app.repository.updateServer(server);
    await shortcuts?.pushServer(server);
  }

  /// Delete a host and everything that referenced it.
  ///
  /// Also clears the selection when the deleted host was the selected one, so the screens do not
  /// keep operating against an id that no longer resolves.
  Future<void> deleteServer(int serverId) async {
    await _app.repository.deleteServerAndDependents(serverId);
    await shortcuts?.removeServer(serverId);
    if (_app.selectedServerId == serverId) _app.selectedServerId = null;
    _selectedServerIdsForBulk.remove(serverId);
    notifyListeners();
  }

  Future<void> deleteSelectedServers() async {
    final ids = List<int>.from(_selectedServerIdsForBulk);
    for (final id in ids) {
      await _app.repository.deleteServerAndDependents(id);
      await shortcuts?.removeServer(id);
      if (_app.selectedServerId == id) _app.selectedServerId = null;
    }
    _selectedServerIdsForBulk.clear();
    _isMultiSelectMode = false;
    notifyListeners();
  }

  /// Apply a group name to every bulk-selected host.
  Future<void> setGroupForSelected(String groupName) async {
    final ids = List<int>.from(_selectedServerIdsForBulk);
    for (final id in ids) {
      final matches = servers.where((s) => s.id == id);
      final server = matches.isEmpty ? null : matches.first;
      if (server == null) continue;
      await _app.repository.updateServer(
        server.copyWith(groupName: Value(groupName)),
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _app.removeListener(notifyListeners);
    super.dispose();
  }
}
