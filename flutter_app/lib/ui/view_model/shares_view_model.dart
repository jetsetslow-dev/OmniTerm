import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/network/network_probe.dart';
import '../../domain/network_share_form.dart';
import 'app_state.dart';

/// The Network Shares tab's state and actions, ported from `NetworkSharesTab` in `ui/SftpScreen.kt`.
///
/// Saved share *profiles*: where a share lives and how to authenticate to it. Reachability is
/// checked with a plain TCP connect, matching the Kotlin — not a protocol handshake, because the
/// point is "is this thing on the network right now", answered in a second without prompting for
/// credentials.
class SharesViewModel extends ChangeNotifier {
  SharesViewModel(this._app, {NetworkProbe? probe}) : probe = probe ?? const SocketNetworkProbe() {
    _sharesSub = _app.repository.networkSharesStream.listen((rows) {
      _shares = rows;
      _safeNotify();
    });
  }

  final AppState _app;
  final NetworkProbe probe;

  StreamSubscription<List<NetworkShare>>? _sharesSub;
  List<NetworkShare> _shares = const [];

  List<NetworkShare> get shares => List.unmodifiable(_shares);

  bool _disposed = false;

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
    // Seeded with the default port for the default protocol, so the commonest case needs no typing.
    _draft = NetworkShareDraft(port: '${ShareProtocol.smb.defaultPort}');
    _error = null;
    _safeNotify();
  }

  void startEdit(NetworkShare share) {
    _draft = NetworkShareDraft.fromShare(share);
    _error = null;
    _safeNotify();
  }

  void updateDraft(NetworkShareDraft Function(NetworkShareDraft) change) {
    final current = _draft;
    if (current == null) return;
    _draft = change(current);
    _safeNotify();
  }

  void cancelEdit() {
    _draft = null;
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
      await _app.repository.insertNetworkShare(
        current.toShare(
          lastChecked: existing?.lastChecked ?? 0,
          lastStatus: existing?.lastStatus ?? 'unknown',
        ),
      );
      _draft = null;
      _status = 'Saved "${current.name.trim()}".';
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
        share.copyWith(
          lastStatus: status,
          lastChecked: DateTime.now().millisecondsSinceEpoch,
        ),
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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sharesSub?.cancel());
    super.dispose();
  }
}
