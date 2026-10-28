import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/network/network_probe.dart';
import '../../domain/network_share_form.dart';
import '../../domain/share_scan.dart';
import '../../platform/long_operation_notifications.dart';
import 'app_state.dart';

/// The Network Shares tab's state and actions, ported from `NetworkSharesTab` in `ui/SftpScreen.kt`.
///
/// Saved share *profiles*: where a share lives and how to authenticate to it. Reachability is
/// checked with a plain TCP connect, matching the Kotlin — not a protocol handshake, because the
/// point is "is this thing on the network right now", answered in a second without prompting for
/// credentials.
class SharesViewModel extends ChangeNotifier {
  SharesViewModel(this._app, {NetworkProbe? probe, this.operationNotifications})
    : probe = probe ?? const SocketNetworkProbe() {
    _sharesSub = _app.repository.networkSharesStream.listen((rows) {
      _shares = rows;
      _safeNotify();
    });
    // The cards name a share's credential profile, so the list is needed before any form opens.
    unawaited(_loadProfiles());
  }

  final AppState _app;
  final NetworkProbe probe;
  final LongOperationNotifications? operationNotifications;
  int _operationSequence = 0;

  StreamSubscription<List<NetworkShare>>? _sharesSub;
  List<NetworkShare> _shares = const [];

  List<NetworkShare> get shares => List.unmodifiable(_shares);

  bool _disposed = false;

  /// Surfaces a refused foreground-service start, and only a refused one.
  ///
  /// The result used to be discarded entirely. A refusal means the work the user just started will
  /// not survive them switching away, which is the whole point of the service — so it is worth
  /// saying, once, in this screen's existing error surface. `unsupported` stays silent: iOS and
  /// desktop have no foreground service and never will, and a permanent unactionable warning is
  /// worse than none at all.
  void _noteStartResult(LongOperationStart result) {
    final warning = result.warning;
    if (warning == null || _disposed) return;
    if (_error == warning) return;
    _error = warning;
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  String? _status;
  String? _error;

  String? get status => _status;
  String? get error => _error;

  void dismissMessages() {
    _status = null;
    _error = null;
    _safeNotify();
  }

  /// Shares currently being probed, so their cards can say "checking" rather than sit still.
  final Set<int> _checking = {};

  bool isChecking(int id) => _checking.contains(id);

  // ── editing ─────────────────────────────────────────────────────────────────

  NetworkShareDraft? _draft;

  NetworkShareDraft? get draft => _draft;

  void startAdd() {
    // Kotlin's new share: SMB on its default port, anonymous, HTTPS off until WebDAV is picked.
    _draft = NetworkShareDraft(
      port: '${ShareProtocol.smb.defaultPort}',
      anonymous: true,
      useHttps: false,
    );
    _draftSeenOnlineAt = null;
    _error = null;
    unawaited(_loadProfiles());
    _safeNotify();
  }

  void startEdit(NetworkShare share) {
    _draft = NetworkShareDraft.fromShare(share);
    _draftSeenOnlineAt = null;
    _error = null;
    unawaited(_loadProfiles());
    _safeNotify();
  }

  List<CredentialProfile> _profiles = const [];

  /// Saved credential profiles, offered as chips beside "New profile" in the form.
  List<CredentialProfile> get profiles => List.unmodifiable(_profiles);

  /// How a share signs in, as Kotlin's card words it.
  String authLabel(NetworkShare share) {
    if (share.anonymous) return 'anonymous';
    final profile = _profiles.where((p) => p.id == share.authProfileId).firstOrNull;
    if (profile != null) return 'profile: ${profile.profileName}';
    final parts = [share.workgroup, share.username].where((p) => p.trim().isNotEmpty);
    return parts.isEmpty ? 'credentials' : parts.join(r'\');
  }

  Future<void> _loadProfiles() async {
    try {
      _profiles = await _app.repository.getAllProfiles();
      _safeNotify();
    } catch (_) {
      // The form still works with "New profile"; a profile list that fails to load costs a chip.
    }
  }

  void updateDraft(NetworkShareDraft Function(NetworkShareDraft) change) {
    final current = _draft;
    if (current == null) return;
    _draft = change(current);
    _safeNotify();
  }

  void cancelEdit() {
    _draft = null;
    _draftSeenOnlineAt = null;
    _safeNotify();
  }

  /// Returns true when the draft was saved.
  Future<bool> saveDraft() async {
    final current = _draft;
    if (current == null) return false;
    if (!current.isValid) {
      _safeNotify();
      return false;
    }

    try {
      // The existing status is carried over rather than reset: editing a share's notes should not
      // make a host that was reachable a moment ago suddenly read as unknown.
      final existing = _shares.where((s) => s.id == current.id).firstOrNull;
      // Kotlin's `persistNetworkShare`: typed credentials become a reusable profile in the "Network
      // Shares" group, and the share points at it instead of holding the password itself.
      final newProfile = current.profileToCreate;
      final profileId = newProfile == null ? null : await _app.repository.insertProfile(newProfile);
      final seenAt = _draftSeenOnlineAt;
      final share = current.toShare(
        lastChecked: existing?.lastChecked ?? seenAt ?? 0,
        lastStatus: existing?.lastStatus ?? (seenAt == null ? 'unknown' : 'online'),
        createdProfileId: profileId,
      );
      await _app.repository.insertNetworkShare(share);
      if (profileId != null) await _loadProfiles();
      _draft = null;
      _draftSeenOnlineAt = null;
      _status = 'Saved ${share.name}.';
      _error = null;
      _safeNotify();
      return true;
    } catch (e) {
      _error = 'Could not save that share: $e';
      _safeNotify();
      return false;
    }
  }

  Future<void> delete(NetworkShare share) async {
    try {
      await _app.repository.deleteNetworkShareById(share.id);
      // Saying what was *not* touched, because "delete" next to a file browser reads as destructive.
      _status = 'Removed "${share.name}". Files on the share are untouched.';
      _error = null;
    } catch (e) {
      _error = 'Could not remove that share: $e';
    }
    _safeNotify();
  }

  // ── reachability ────────────────────────────────────────────────────────────

  static const probeTimeout = Duration(milliseconds: 1200);

  /// Probe one share.
  Future<void> test(NetworkShare share) async {
    if (_checking.contains(share.id)) return;
    _checking.add(share.id);
    _safeNotify();

    String status;
    try {
      final rtt = await probe.tcpPing(share.address, share.port, timeout: probeTimeout);
      // "unreachable", not "offline": a host that is up but not listening on this port looks
      // identical from here, and claiming the machine is down would send the user hunting the
      // wrong problem.
      status = rtt == null ? 'unreachable' : 'online';
    } catch (_) {
      status = 'unreachable';
    }

    _checking.remove(share.id);
    try {
      await _app.repository.insertNetworkShare(
        share.copyWith(lastStatus: status, lastChecked: DateTime.now().millisecondsSinceEpoch),
      );
    } catch (_) {
      // The probe result is still worth showing even if it could not be recorded.
    }
    _status = '${share.name}: $status on ${share.address}:${share.port}.';
    _safeNotify();
  }

  /// Probe every saved share, a few at a time.
  ///
  /// Bounded because an unbounded sweep of a large share list opens one socket per share at once —
  /// on a phone that is a self-inflicted connection storm, and on a slow link every one of them
  /// waits out the full timeout together.
  static const maxConcurrentProbes = 8;

  Future<void> testAll() async {
    final pending = List<NetworkShare>.from(_shares);
    if (pending.isEmpty) return;
    final queue = pending.iterator;
    Future<void> worker() async {
      while (true) {
        if (_disposed) return;
        if (!queue.moveNext()) return;
        await test(queue.current);
      }
    }

    await Future.wait(
      List.generate(
        pending.length < maxConcurrentProbes ? pending.length : maxConcurrentProbes,
        (_) => worker(),
      ),
    );
    if (!_disposed) _status = 'Checked ${pending.length} share(s).';
    _safeNotify();
  }

  // ── finding shares on the network ───────────────────────────────────────────

  List<String> _scanProtocols = allScanProtocols;
  final List<ShareScanHit> _scanHits = [];
  bool _scanning = false;
  String? _scanStatus;
  int _scanDone = 0;
  int _scanTotal = 0;

  List<String> get scanProtocols => List.unmodifiable(_scanProtocols);
  List<ShareScanHit> get scanHits => List.unmodifiable(_scanHits);
  bool get scanning => _scanning;
  String? get scanStatus => _scanStatus;

  /// Sweep progress from 0 to 1, or null before one starts.
  double? get scanProgress => _scanTotal == 0 ? null : (_scanDone / _scanTotal).clamp(0.0, 1.0);

  bool isScanProtocolEnabled(String protocol) => _scanProtocols.contains(protocol);

  /// Loads the stored protocol selection. Called by the screen on first build.
  Future<void> loadScanSettings() async {
    _scanProtocols = decodeScanProtocols(await _app.repository.getSetting(shareScanProtocolsKey));
    _safeNotify();
  }

  /// Turns a protocol on or off for the next sweep.
  ///
  /// **The last one cannot be turned off**, matching `toggleNetworkShareScanProtocol`
  /// (`ui/AppViewModel.kt:1181`): a scan with no protocols probes no ports and reports nothing
  /// found, which is indistinguishable from a quiet network.
  Future<void> toggleScanProtocol(String protocol) async {
    if (!shareScanPorts.containsKey(protocol)) return;
    if (_scanProtocols.contains(protocol)) {
      if (_scanProtocols.length <= 1) return;
      _scanProtocols = _scanProtocols.where((p) => p != protocol).toList();
    } else {
      // Rebuilt from the canonical order so the stored value does not depend on the order the user
      // happened to tap the chips in.
      _scanProtocols = allScanProtocols
          .where((p) => p == protocol || _scanProtocols.contains(p))
          .toList();
    }
    _safeNotify();
    await _app.repository.insertSetting(shareScanProtocolsKey, encodeScanProtocols(_scanProtocols));
  }

  /// Kotlin's `scanNetworkShares`: probes the hosts [input] names for the selected protocols.
  ///
  /// [input] is a `/24` subnet or one host ([shareScanTargets]). Blank means this device's own
  /// network, and [lanTargets] supplies it: the hosts the shared LAN sweep found, or the whole /24.
  Future<void> scanForShares(String input, {Future<List<String>> Function()? lanTargets}) async {
    if (_scanning) return;
    final typed = input.trim();
    final protocols = _scanProtocols.join(', ');

    final operationId =
        'share-scan-${DateTime.now().microsecondsSinceEpoch}-${_operationSequence++}';
    final notifications = operationNotifications;
    if (notifications != null) {
      unawaited(
        notifications
            .start(id: operationId, label: 'Scanning for network shares', destination: 'network')
            .then(_noteStartResult),
      );
    }
    var succeeded = false;
    _scanning = true;
    _scanHits.clear();
    _scanDone = 0;
    _scanTotal = 0;
    _error = null;
    _scanStatus = typed.isEmpty
        ? 'Scanning LAN hosts, then probing $protocols.'
        : 'Scanning share services for $protocols.';
    _safeNotify();

    try {
      final targets = typed.isEmpty
          ? await lanTargets?.call() ?? const <String>[]
          : shareScanTargets(typed);
      if (_disposed) return;
      if (targets.isEmpty) {
        _scanStatus = 'Enter a /24 subnet like 192.168.1.0/24, or leave it blank on Wi-Fi/LAN.';
        return;
      }
      _scanStatus = 'Scanning ${targets.length} host(s) for $protocols.';
      _safeNotify();
      // Kotlin's budget: a 700 ms connect per port, at most 64 at a time.
      final hosts = await probeHosts(
        probe,
        targets,
        ports: portsForProtocols(_scanProtocols),
        concurrency: 64,
        timeout: const Duration(milliseconds: 700),
        onProgress: (done, total) {
          _scanDone = done;
          _scanTotal = total;
          _safeNotify();
        },
      );
      if (_disposed) return;
      _scanHits.addAll(hitsFromScan(hosts, _scanProtocols));
      _scanStatus = 'Scan complete: ${_scanHits.length} candidate share service(s).';
      succeeded = true;
    } catch (e) {
      // Said in the scan dialog, where the user is looking; the tab's message card is behind it.
      _scanStatus = 'Scan failed: $e';
    } finally {
      _scanning = false;
      if (notifications != null) {
        unawaited(notifications.finish(id: operationId, success: succeeded));
      }
      _safeNotify();
    }
  }

  /// What the scan dialog's "Subnet or host" field holds: Kotlin's `networkShareScanCidr`, kept
  /// here so closing the dialog and opening it again finds the same input.
  ///
  /// Prefilled once from an address the user already saved, because the subnet they want is almost
  /// always the one their existing shares are on. Left blank when there is nothing to infer from,
  /// which scans this device's own network.
  String scanInput = '';
  bool _scanInputPrefilled = false;

  /// Loads the protocol selection and prefills [scanInput]; called as the scan dialog opens.
  Future<void> prepareScan() async {
    await loadScanSettings();
    if (_scanInputPrefilled || scanInput.isNotEmpty) return;
    _scanInputPrefilled = true;
    final prefix = _shares.map((s) => scanPrefixOf(s.address)).whereType<String>().firstOrNull;
    if (prefix != null) {
      scanInput = '$prefix.0/24';
      _safeNotify();
    }
  }

  void clearScanHits() {
    if (_scanHits.isEmpty && _scanStatus == null) return;
    _scanHits.clear();
    _scanStatus = null;
    _scanDone = 0;
    _scanTotal = 0;
    _safeNotify();
  }

  /// Opens the add-share form prefilled from [hit]: Kotlin's `shareDraftFromScan`.
  ///
  /// The share **path and credentials are left blank on purpose**: a port probe says a service is
  /// listening, not what it exports or who may read it. Guessing either would produce a saved share
  /// that fails on first use with no clue why.
  void startAddFromScan(ShareScanHit hit) {
    _draft = NetworkShareDraft.fromScan(hit);
    _draftSeenOnlineAt = DateTime.now().millisecondsSinceEpoch;
    _error = null;
    unawaited(_loadProfiles());
    _safeNotify();
  }

  /// When the open draft came from a scan hit, the time that hit answered. Kotlin's scan draft is
  /// saved as seen online then, so the new card reads Available rather than Unknown.
  int? _draftSeenOnlineAt;

  /// Kotlin's `addNetworkShareFromScan`: saves [hit] as it stands, signed in as a guest.
  ///
  /// SMB and SFTP are refused here, as in Kotlin: SMB needs a share path and SFTP an account, so
  /// the dialog opens the form for those instead.
  Future<void> saveFromScan(ShareScanHit hit) async {
    final protocol = ShareProtocol.fromId(hit.protocol);
    if (protocol == ShareProtocol.smb || protocol == ShareProtocol.sftp) {
      _scanStatus = '${hit.protocol} needs configuration before saving.';
      _safeNotify();
      return;
    }
    try {
      final share = NetworkShareDraft.fromScan(
        hit,
      ).toShare(lastChecked: DateTime.now().millisecondsSinceEpoch, lastStatus: 'online');
      await _app.repository.insertNetworkShare(share);
      _scanHits.remove(hit);
    } catch (e) {
      _scanStatus = 'Save failed: $e';
    }
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sharesSub?.cancel());
    super.dispose();
  }
}
