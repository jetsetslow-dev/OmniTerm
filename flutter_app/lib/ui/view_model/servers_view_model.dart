import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart' show hasUnixShell;
import '../../data/remote_models.dart';
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../data/ssh/ssh_tunnel_manager.dart';
import '../../domain/host_limit.dart';
import '../../domain/host_list.dart';
import '../../domain/health_scoring.dart';
import '../../domain/measurement_units.dart';
import '../../domain/saved_tmux_sessions.dart';
import '../../domain/server_credentials.dart';
import '../../domain/ssh_failure.dart';
import '../../platform/shortcut_helper.dart';
import 'app_state.dart';
import 'shell_view_model.dart';

/// The Servers screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
///
/// Owns only what the Servers screen needs — search text, the group filter, multi-select — and reads
/// the host list from the shared [AppState] rather than holding a second copy that could drift.
class ServersViewModel extends ChangeNotifier {
  ServersViewModel(
    this._app, {
    this.transport,
    this.shortcuts,
    this.probeHost,
    this.pollHost,
    this.shell,
    this.tunnels,
    this.hostKeyTrust,
  }) {
    _app.addListener(notifyListeners);
  }

  final AppState _app;

  /// Null in tests and in any build without a transport wired; Test Connection is then unavailable
  /// rather than silently reporting success.
  final SshTransport? transport;
  final ShortcutHelper? shortcuts;

  /// Checks one host through its configured route. Kotlin's `addServer` probes a new host as soon as
  /// it is saved; without that the card sits on its stored `offline` until the next sweep.
  final Future<void> Function(Server server)? probeHost;

  /// Takes one metrics sample from a host now ([TelemetryPoller.pollOne]), for [refreshServer].
  final Future<String?> Function(Server server)? pollHost;

  /// The Shell tab, which a deleted host's terminals and tmux sessions belong to. Read when needed
  /// because its view model is created after this one.
  final ShellViewModel Function()? shell;

  /// Stops a deleted host's running tunnels, which would otherwise hold their ports open.
  final SshTunnelManager? tunnels;

  /// Forgets a deleted host's trusted keys.
  final SshHostKeyTrust? hostKeyTrust;

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

  HostSort get hostSort => _app.hostSort;
  Future<void> updateHostSort(HostSort sort) => _app.updateHostSort(sort);

  /// False for a host already known to run Windows, which has no tmux to attach. A host not yet
  /// probed counts as Unix, as Kotlin's blank `knownOs` does.
  bool hasKnownUnixShell(Server server) => hasUnixShell(_app.osForServer(server.id));

  /// When [serverId] last answered, for an offline host's "Last seen" line. See
  /// [AppState.lastSeenAt].
  int? lastSeenAt(int serverId) => _app.lastSeenAt(serverId);

  /// [sshCommandFor] with the user a credential profile signs in as, for the ⋮ menu's copy.
  Future<String> sshCommand(Server server) async {
    final profileId = server.authProfileId;
    final profile = server.authType == 'profile' && profileId != null
        ? await _app.repository.getCredentialProfileById(profileId)
        : null;
    return sshCommandFor(server, profile?.username ?? server.username);
  }

  HealthBreakdown healthBreakdown(Server server, HostMetrics? metrics) => metrics == null
      ? HealthBreakdown.unavailable
      : _app.healthScoring.breakdown(
          metrics.cpuPercent,
          metrics.memPercent,
          metrics.diskPercent,
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

  List<int> get selectedServerIdsForBulk => List.unmodifiable(_selectedServerIdsForBulk);

  /// The aliases of every stored SSH key, for the form's key picker.
  Future<List<String>> savedKeyAliases() async =>
      (await _app.repository.getAllKeys()).map((k) => k.alias).toList();

  Future<List<CredentialProfile>> savedProfiles() => _app.repository.getAllProfiles();

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
      final endpointUnreachable = failure != null && sshFailureProvesEndpointUnreachable(failure);
      await Future.wait([
        _app.repository.updateConnectionState(
          candidate.id,
          endpointUnreachable ? 'offline' : 'online',
          endpointUnreachable ? 0 : candidate.healthScore,
          0,
        ),
        _app.repository.updateAuthState(candidate.id, failure == null ? 'ok' : 'failed', failure),
      ]);
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

  /// True when the install already holds **more** hosts than its entitlement allows.
  ///
  /// Distinct from [hostLimitReached], which stops a *new* host being added. This is the standing
  /// violation: a restore on an older build, a lapsed unlock or a refund all leave hosts already
  /// saved, and blocking additions does nothing about those.
  bool hostLimitExceededNow({required bool playStoreBuild, required bool unlocked}) =>
      hostLimitExceeded(
        hasHostLimit: playStoreBuild && !unlocked,
        hostLimit: freePlayStoreLimit,
        hostCount: servers.length,
      );

  /// Keeps [keepIds] and deletes every other saved host, as Kotlin's `keepOnlyHostAfterLimitChange`.
  /// The removed hosts' tmux sessions keep running unless [endTmuxSessions]. SSH keys no kept host
  /// signs in with go too, since the free tier's credential limit applies as well.
  ///
  /// Refuses a selection that is not exactly the limit rather than doing something approximate:
  /// this deletes hosts, and a flow that deletes more than the user chose — or leaves the install
  /// still over its limit — is worse than one that declines. Returns how many were removed.
  Future<int> reconcileHostLimit(Set<int> keepIds, {bool endTmuxSessions = false}) async {
    if (!isValidHostKeepSelection(selectedCount: keepIds.length, hostLimit: freePlayStoreLimit)) {
      return 0;
    }
    final all = await _app.repository.getAllServers();
    final kept = all.where((s) => keepIds.contains(s.id)).toList();
    if (kept.length != keepIds.length) return 0;
    final doomed = all.where((s) => !keepIds.contains(s.id)).toList();
    var unconfirmed = false;
    for (final server in doomed) {
      if (await _removeServer(server, endTmuxSessions: endTmuxSessions, remaining: kept)) {
        unconfirmed = true;
      }
    }
    final profiles = await _app.repository.getAllProfiles();
    final usedKeys = {
      for (final server in kept) ...[
        server.authKeyAlias,
        server.proxyKeyAlias,
        profiles.where((p) => p.id == server.authProfileId).firstOrNull?.keyAlias,
      ],
    };
    for (final key in await _app.repository.getAllKeys()) {
      if (!usedKeys.contains(key.alias)) await _app.repository.deleteKey(key);
    }
    _app.selectedServerId = kept.first.id;
    _selectedServerIdsForBulk.removeWhere((id) => !keepIds.contains(id));
    notifyListeners();
    if (unconfirmed) shell?.call().reportUnendedTmuxAfterDelete(HostDeletion.limit);
    return doomed.length;
  }

  // ── actions ────────────────────────────────────────────────────────────────

  /// Kotlin's free-tier message when a credential cannot be added (`credentialProfileLimitMessage`).
  static const credentialLimitMessage =
      'The free Play Store build supports 1 authentication method. Unlock OmniTerm to save '
      'unlimited credentials.';

  /// Saves a new host. [createProfile] is Kotlin's "Save securely to Credential Store": with a
  /// password typed, it also stores that password as a reusable credential profile named
  /// `<host name> profile` (the host keeps its own copy, exactly as `addServer` does).
  Future<int> saveServer(
    Server server, {
    bool createProfile = false,
    bool credentialLimitReached = false,
  }) async {
    final password = server.authPassword ?? '';
    final makeProfile = createProfile && server.authType == 'password' && password.isNotEmpty;
    if (makeProfile && credentialLimitReached) throw Exception(credentialLimitMessage);
    final id = await _app.repository.saveUniqueServer(server);
    if (makeProfile) {
      await _app.repository.insertProfile(
        CredentialProfile(
          id: 0,
          profileName: '${server.name} profile',
          username: server.username,
          authType: 'password',
          password: password,
          groupName: 'General',
        ),
      );
    }
    final probe = probeHost;
    if (probe != null) {
      final saved = await _app.repository.getServerById(id);
      if (saved != null) unawaited(probe(saved));
    }
    return id;
  }

  /// Saves an edited host, as Kotlin's `updateServer`. Its sessions show its new name, and its
  /// pooled connection is dropped so the next one uses the new settings. A host now at another
  /// address or port is measured afresh rather than showing the old machine's health. Returns a
  /// notice when running tunnels still use the previous settings.
  Future<String?> updateServer(Server server) async {
    final previous = await _app.repository.getServerById(server.id);
    final previousCreds = previous == null ? null : await _credentialsOrNull(previous);
    await _app.repository.saveUniqueServer(server, update: true);
    // Keeps a launcher shortcut's label in step with a rename.
    await shortcuts?.pushServer(server);
    if (previousCreds != null) transport?.forgetCredentials(previousCreds);
    final creds = await _credentialsOrNull(server);
    final moved =
        previous != null && (previous.host != server.host || previous.port != server.port);
    await shell?.call().hostEdited(server, moved: moved);
    if (moved) {
      // Health, metrics and sparklines describe the old address. Measure the new one.
      await _app.invalidateCurrentHealth(
        server.id,
        'Host address changed. Waiting for current metrics.',
      );
      await _app.repository.updateReachability(server.id, 'connecting', 0);
      final updated = await _app.repository.getServerById(server.id);
      final probe = probeHost;
      if (updated != null && probe != null) unawaited(probe(updated));
    }
    final tunnels = this.tunnels;
    if (creds == previousCreds || tunnels == null) return null;
    final running = (await _app.repository.getAllPortForwards())
        .where((forward) => forward.serverId == server.id && tunnels.isActive(forward.id))
        .length;
    return switch (running) {
      0 => null,
      1 =>
        '1 running tunnel still uses the previous connection settings. Restart it to apply the '
            'changes.',
      _ =>
        '$running running tunnels still use the previous connection settings. Restart them to '
            'apply the changes.',
    };
  }

  /// Why online [serverId] has no current metrics, if there is a reason to give.
  String? metricsErrorFor(int serverId) => _app.metricsErrorFor(serverId);

  /// Whether the tabs that need a live connection offer [server]; see [AppState.isPickableHost].
  bool isPickableHost(Server server) => _app.isPickableHost(server);

  /// Re-checks one host, as Kotlin's `refreshServer` (a card's Retry, or a pull on Monitor's
  /// Overview): shown as being checked unless [markChecking] is false, then probed and measured.
  /// Returns why the host still has no current metrics, or null when it has them.
  Future<String?> refreshServer(int serverId, {bool markChecking = true}) async {
    final before = await _app.repository.getServerById(serverId);
    if (before == null) return 'Refresh failed: host was removed.';
    // Without a probe nothing would answer, and the host would read "Checking host…" for good.
    if (markChecking && probeHost != null) await _app.markChecking([before]);
    try {
      await probeHost?.call(before);
      final probed = await _app.repository.getServerById(serverId);
      final poll = pollHost;
      if (probed != null && probed.status == 'online' && poll != null) await poll(probed);
    } finally {
      _app.doneRechecking([serverId]);
    }
    final refreshed = await _app.repository.getServerById(serverId);
    if (refreshed == null) return 'Refresh failed: host was removed.';
    if (refreshed.status == 'offline') {
      return 'Refresh failed for ${before.name}: the host did not respond on its configured SSH '
          'route.';
    }
    if (refreshed.authStatus == 'failed') {
      return 'Refresh failed for ${before.name}: '
          '${refreshed.authError ?? 'SSH authentication failed.'}';
    }
    if (refreshed.healthScore < 0) {
      return 'Refresh failed for ${before.name}: '
          '${_app.metricsErrorFor(serverId) ?? 'Current metrics could not be verified.'}';
    }
    return null;
  }

  /// [server]'s SSH credentials, or null when its saved settings cannot make any.
  Future<SshCredentials?> _credentialsOrNull(Server server) async {
    try {
      return resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
    } on CredentialResolutionException {
      return null;
    }
  }

  /// How many tmux sessions deleting [serverIds] would leave running, for the delete dialog's
  /// offer to end them.
  int tmuxSessionCount(Set<int> serverIds) =>
      shell?.call().tmuxSessionsOnHosts(serverIds).length ?? 0;

  /// Deletes a host and everything stored for it. Its tmux sessions keep running on the server
  /// unless [endTmuxSessions], since the dialog promises the remote machine is otherwise untouched.
  Future<void> deleteServer(int serverId, {bool endTmuxSessions = false}) async {
    final all = await _app.repository.getAllServers();
    final server = all.where((s) => s.id == serverId).firstOrNull;
    if (server == null) return;
    final unconfirmed = await _removeServer(
      server,
      endTmuxSessions: endTmuxSessions,
      remaining: [
        for (final s in all)
          if (s.id != serverId) s,
      ],
    );
    _selectedServerIdsForBulk.remove(serverId);
    notifyListeners();
    if (unconfirmed) shell?.call().reportUnendedTmuxAfterDelete(HostDeletion.one);
  }

  /// Deletes every bulk-selected host the way [deleteServer] deletes one, and leaves multi-select.
  Future<void> deleteSelectedServers({bool endTmuxSessions = false}) async {
    final ids = _selectedServerIdsForBulk.toSet();
    _selectedServerIdsForBulk.clear();
    _isMultiSelectMode = false;
    notifyListeners();
    final all = await _app.repository.getAllServers();
    final remaining = all.where((s) => !ids.contains(s.id)).toList();
    var unconfirmed = false;
    for (final server in all.where((s) => ids.contains(s.id))) {
      if (await _removeServer(server, endTmuxSessions: endTmuxSessions, remaining: remaining)) {
        unconfirmed = true;
      }
    }
    if (unconfirmed) shell?.call().reportUnendedTmuxAfterDelete(HostDeletion.several);
  }

  /// The work behind every host delete, as Kotlin's `removeServer`: the host's terminals close, its
  /// tmux sessions end when asked, its tunnels stop and its pooled connections are dropped before
  /// its rows go. Its trusted keys go too unless one of [remaining] uses the same address. Returns
  /// true when a tmux session it was asked to end could not be confirmed stopped.
  Future<bool> _removeServer(
    Server server, {
    required bool endTmuxSessions,
    required List<Server> remaining,
  }) async {
    // Nothing can have connected without credentials, so without any there is nothing to drop.
    final creds = await _credentialsOrNull(server);
    final unconfirmed =
        await shell?.call().releaseHost(server, endTmuxSessions: endTmuxSessions) ?? false;
    final tunnels = this.tunnels;
    if (tunnels != null) {
      for (final forward in await _app.repository.getAllPortForwards()) {
        if (forward.serverId == server.id) await tunnels.stop(forward.id);
      }
    }
    if (creds != null) transport?.forgetCredentials(creds);
    await _app.repository.deleteServerAndDependents(server.id);
    // Launcher shortcuts must not outlive the host they open.
    await shortcuts?.removeServer(server.id);
    if (!keepTrustedHostKeys(server.host, remaining)) {
      await hostKeyTrust?.removeHost(server.host, server.port);
    }
    if (_app.selectedServerId == server.id) _app.selectedServerId = null;
    return unconfirmed;
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
