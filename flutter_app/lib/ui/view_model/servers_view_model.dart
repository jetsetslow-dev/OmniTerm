import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/server_credentials.dart';
import 'app_state.dart';

/// The Servers screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Owns only what the Servers screen needs — search text, the group filter, multi-select — and reads
/// the host list from the shared [AppState] rather than holding a second copy that could drift.
class ServersViewModel extends ChangeNotifier {
  ServersViewModel(this._app, {this.transport}) {
    _app.addListener(notifyListeners);
  }

  final AppState _app;

  /// Null in tests and in any build without a transport wired; Test Connection is then unavailable
  /// rather than silently reporting success.
  final SshTransport? transport;

  bool get canTestConnections => transport != null;

  /// The Play Store free tier allows one saved host; the source-available build is unlimited.
  static const freePlayStoreLimit = 1;

  String _serverSearchText = '';
  String? _selectedGroupChip = 'All';
  bool _isMultiSelectMode = false;
  final List<int> _selectedServerIdsForBulk = [];

  List<Server> get servers => _app.servers;
  Server? get selectedServer => _app.selectedServer;
  int? get selectedServerId => _app.selectedServerId;
  set selectedServerId(int? value) => _app.selectedServerId = value;

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

  List<int> get selectedServerIdsForBulk => List.unmodifiable(_selectedServerIdsForBulk);

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
    if (transport == null) return 'Connection testing is unavailable in this build.';
    try {
      final creds = resolveCredentials(
        candidate,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      return await transport.testConnection(creds);
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
            (_selectedGroupChip == 'All' || server.groupName == _selectedGroupChip))
          server,
    ];
  }

  /// True when the free-tier host limit has been reached.
  ///
  /// [unlocked] comes from the billing controller; the source-available build passes true because it
  /// carries no billing code at all.
  bool hostLimitReached({required bool playStoreBuild, required bool unlocked}) =>
      playStoreBuild && !unlocked && servers.length >= freePlayStoreLimit;

  // ── actions ────────────────────────────────────────────────────────────────

  Future<int> saveServer(Server server) => _app.repository.insertServer(server);

  Future<void> updateServer(Server server) => _app.repository.updateServer(server);

  /// Delete a host and everything that referenced it.
  ///
  /// Also clears the selection when the deleted host was the selected one, so the screens do not
  /// keep operating against an id that no longer resolves.
  Future<void> deleteServer(int serverId) async {
    await _app.repository.deleteServerAndDependents(serverId);
    if (_app.selectedServerId == serverId) _app.selectedServerId = null;
    _selectedServerIdsForBulk.remove(serverId);
    notifyListeners();
  }

  Future<void> deleteSelectedServers() async {
    final ids = List<int>.from(_selectedServerIdsForBulk);
    for (final id in ids) {
      await _app.repository.deleteServerAndDependents(id);
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
      await _app.repository.updateServer(server.copyWith(groupName: Value(groupName)));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _app.removeListener(notifyListeners);
    super.dispose();
  }
}
