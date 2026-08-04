import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/app_repository.dart';
import '../../data/network/network_probe.dart';

/// Keeps every saved host's `status` column current.
///
/// **Nothing else in the app writes it, and almost everything reads it.** Monitor, Infra, Fleet, the
/// SFTP browser and the terminal all offer only hosts whose status is `online`, so without this the
/// app shows "no online hosts" on every screen no matter how reachable the machines are — which is
/// exactly what a device run turned up (§15.8).
///
/// Ported from `probeServer` in `ui/AppViewModel.kt`. Deliberately **TCP reachability only**: the
/// question this answers is "can I reach the SSH port right now", which is what the screens filter
/// on. A full SSH handshake per host per cycle would authenticate dozens of times a minute, and the
/// screens that need a real session open one themselves.
class HostStatusProbe extends ChangeNotifier {
  HostStatusProbe(
    this._repository, {
    NetworkProbe? probe,
    this.interval = const Duration(seconds: 45),
  }) : probe = probe ?? const SocketNetworkProbe();

  final AppRepository _repository;
  final NetworkProbe probe;

  /// How often the sweep repeats once [start] is called.
  final Duration interval;

  /// Long enough for a busy host on a slow link, short enough that a sweep of a large fleet does not
  /// take minutes when most of it is down.
  static const timeout = Duration(seconds: 4);

  /// At most this many sockets at once. An unbounded sweep opens one per host simultaneously, which
  /// on a phone exhausts file descriptors and battery on a fleet of any size.
  static const maxConcurrent = 8;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  bool get isRunning => _running;

  /// Probe now, then keep probing on [interval].
  void start() {
    _timer?.cancel();
    unawaited(sweep());
    _timer = Timer.periodic(interval, (_) => unawaited(sweep()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass over every saved host.
  Future<void> sweep() async {
    // Overlapping sweeps would double the socket count and race each other's writes; a slow sweep
    // simply skips the tick it could not keep up with.
    if (_running || _disposed) return;
    _running = true;
    _safeNotify();

    try {
      final servers = await _repository.getAllServers();
      if (servers.isEmpty || _disposed) return;

      final queue = servers.iterator;
      Future<void> worker() async {
        while (!_disposed && queue.moveNext()) {
          await _probeOne(queue.current);
        }
      }

      await Future.wait(
        List.generate(
          servers.length < maxConcurrent ? servers.length : maxConcurrent,
          (_) => worker(),
        ),
      );
    } catch (_) {
      // A sweep that fails wholesale must not stop the next one; the statuses simply stay as they
      // were, which is the honest outcome for "we could not check".
    } finally {
      _running = false;
      _safeNotify();
    }
  }

  Future<void> _probeOne(Server server) async {
    try {
      // Shown as "connecting" while a previously offline host is retried, so a slow probe reads as
      // work in progress rather than a host that is simply still down.
      if (server.status == 'offline') {
        await _repository.updateConnectionState(server.id, 'connecting', server.healthScore, 0);
      }
      final rtt = await probe.tcpPing(server.host, server.port, timeout: timeout);
      if (_disposed) return;
      if (rtt == null) {
        await _repository.updateConnectionState(server.id, 'offline', 0, 0);
        return;
      }
      // The health score is left alone: it is Monitor's business, computed from real telemetry, and
      // overwriting it from a ping would make a reachable-but-struggling host look perfect.
      await _repository.updateConnectionState(
        server.id,
        'online',
        server.healthScore,
        rtt.inMilliseconds,
      );
    } catch (_) {
      if (_disposed) return;
      // Any failure means "not reachable"; a host stuck at "connecting" forever would be worse than
      // one honestly marked offline.
      await _repository.updateConnectionState(server.id, 'offline', 0, 0).catchError((Object _) {});
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
