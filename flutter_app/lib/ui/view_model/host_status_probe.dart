import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/app_repository.dart';
import '../../data/network/network_probe.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/server_credentials.dart';
import '../../domain/ssh_failure.dart';

/// Keeps every saved host's `status` column current.
///
/// **Nothing else in the app writes it, and almost everything reads it.** Monitor, Infra, Fleet, the
/// SFTP browser and the terminal all offer only hosts whose status is `online`, so without this the
/// app shows "no online hosts" on every screen no matter how reachable the machines are — which is
/// exactly what a device run turned up (§15.8).
///
/// Ported from `probeServer` in `ui/AppViewModel.kt`. A cheap direct TCP check is tried first, but it
/// cannot judge a host reached through HTTP/SOCKS/jump routing. When TCP cannot prove reachability,
/// the configured SSH route is authoritative; otherwise OmniTerm can call a working server
/// "unreachable" merely because the phone has no direct route to its final address.
class HostStatusProbe extends ChangeNotifier {
  HostStatusProbe(
    this._repository, {
    NetworkProbe? probe,
    this.transport,
    this.interval = const Duration(seconds: 45),
  }) : probe = probe ?? const SocketNetworkProbe();

  final AppRepository _repository;
  final NetworkProbe probe;
  final SshTransport? transport;

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
  int _workGeneration = 0;
  int _sweepRunId = 0;

  bool get isRunning => _running;

  /// Probe now, then keep probing on [interval].
  void start() {
    _workGeneration++;
    _sweepRunId++;
    _running = false;
    _activeHostProbes.clear();
    _timer?.cancel();
    unawaited(sweep());
    _timer = Timer.periodic(interval, (_) => unawaited(sweep()));
  }

  void stop() {
    _workGeneration++;
    _sweepRunId++;
    final wasRunning = _running;
    _running = false;
    _activeHostProbes.clear();
    _timer?.cancel();
    _timer = null;
    if (wasRunning) _safeNotify();
  }

  /// One pass over every saved host.
  Future<void> sweep() async {
    // Overlapping sweeps would double the socket count and race each other's writes; a slow sweep
    // simply skips the tick it could not keep up with.
    if (_running || _disposed) return;
    final generation = _workGeneration;
    final runId = ++_sweepRunId;
    _running = true;
    _safeNotify();

    try {
      final servers = await _repository.getAllServers();
      if (servers.isEmpty || !_workIsCurrent(generation)) return;

      final queue = servers.iterator;
      Future<void> worker() async {
        while (_workIsCurrent(generation) && queue.moveNext()) {
          await _probeOne(queue.current, generation);
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
      if (runId == _sweepRunId) {
        _running = false;
        _safeNotify();
      }
    }
  }

  /// Re-check one host immediately (the Retry action on its card).
  /// Hosts this run has actually reached a verdict on.
  ///
  /// Ported from Kotlin's `probedServerIds` (`ui/AppViewModel.kt:4496`). A host's stored status
  /// defaults to `offline` before anything has looked at it, so "offline" on its own cannot be told
  /// apart from "never checked" — and warning "appears offline" about a host the user has just added
  /// is a false alarm at the exact moment they first connect. Kept in memory on purpose: it means
  /// "probed since launch", which is the only thing that makes the stored status trustworthy.
  final Set<int> _probed = <int>{};

  /// Hosts with at least one interactive SSH channel that is open right now.
  ///
  /// A second, background connection can time out or be refused while an existing terminal is
  /// demonstrably carrying traffic (for example when the server limits concurrent handshakes).
  /// That advisory failure must never overwrite stronger live-session evidence.
  final Set<int> _liveSessionServers = <int>{};

  /// Changes whenever interactive-session evidence changes. A probe snapshots this before its
  /// awaits, so one that started before a shell opened cannot race in afterward and write offline.
  final Map<int, int> _evidenceGeneration = <int, int>{};

  /// One check per host. A session-close recheck can coincide with the periodic sweep; sharing the
  /// same future avoids opening two SSH handshakes and lets the close path await the real result.
  final Map<int, Future<void>> _activeHostProbes = <int, Future<void>>{};

  /// Whether [serverId] has been probed since the app started.
  bool hasProbed(int serverId) => _probed.contains(serverId);

  /// Replaces the set of hosts currently backed by an open interactive SSH channel.
  void setLiveSessionServers(Set<int> serverIds) {
    if (_disposed) return;
    final next = serverIds.where((id) => id > 0).toSet();
    final ended = _liveSessionServers.difference(next);
    final changed = <int>{
      ..._liveSessionServers,
      ...next,
    }.where((id) => _liveSessionServers.contains(id) != next.contains(id));
    for (final id in changed) {
      _evidenceGeneration[id] = (_evidenceGeneration[id] ?? 0) + 1;
    }
    _liveSessionServers
      ..clear()
      ..addAll(next);
    for (final id in ended) {
      // The channel that proved reachability has gone away. Recheck immediately instead of showing
      // its old online result until the next 45-second sweep.
      unawaited(_recheckAfterSessionEnded(id));
    }
  }

  bool _workIsCurrent(int generation) => !_disposed && generation == _workGeneration;

  Future<void> probeOne(Server server) => _probeOne(server, _workGeneration);

  /// Promote a host after a real shell has authenticated and opened.
  Future<void> markReachable(Server server) async {
    if (_disposed) return;
    // Bump synchronously, before the database awaits: an older probe can observe this generation
    // immediately and is no longer allowed to commit an offline result.
    _evidenceGeneration[server.id] = (_evidenceGeneration[server.id] ?? 0) + 1;
    _probed.add(server.id);
    await Future.wait([
      _repository.updateConnectionState(
        server.id,
        'online',
        server.healthScore,
        server.lastLatency,
      ),
      _repository.updateAuthState(server.id, 'ok', null),
    ]);
  }

  Future<void> _probeOne(Server server, int generation) {
    if (!_workIsCurrent(generation)) return Future<void>.value();
    final existing = _activeHostProbes[server.id];
    if (existing != null) return existing;
    late final Future<void> running;
    running = _probeOneInner(server, generation).whenComplete(() {
      if (identical(_activeHostProbes[server.id], running)) {
        _activeHostProbes.remove(server.id);
      }
    });
    _activeHostProbes[server.id] = running;
    return running;
  }

  Future<void> _recheckAfterSessionEnded(int serverId) async {
    final inFlight = _activeHostProbes[serverId];
    if (inFlight != null) await inFlight;
    if (_disposed || _liveSessionServers.contains(serverId)) return;
    final server = await _repository.getServerById(serverId);
    if (server != null) await _probeOne(server, _workGeneration);
  }

  Future<void> _probeOneInner(Server server, int generation) async {
    if (!_workIsCurrent(generation)) return;
    if (_liveSessionServers.contains(server.id)) {
      _probed.add(server.id);
      await _preserveInteractiveSuccess(server);
      return;
    }
    final evidenceGeneration = _evidenceGeneration[server.id] ?? 0;
    final stopwatch = Stopwatch()..start();
    try {
      // Shown as "connecting" while a previously offline host is retried, so a slow probe reads as
      // work in progress rather than a host that is simply still down.
      if (server.status == 'offline') {
        await _repository.updateConnectionState(server.id, 'connecting', server.healthScore, 0);
        if (!_workIsCurrent(generation)) return;
      }
      // A direct socket to the final host bypasses every configured proxy. Do not let that result
      // overrule the route the user actually asked SSH to use.
      final rtt = server.proxyType == 'none'
          ? await probe.tcpPing(server.host, server.port, timeout: timeout)
          : null;
      if (!_workIsCurrent(generation)) return;
      if (rtt != null) {
        _probed.add(server.id);
        // The health score is left alone: it is Monitor's business, computed from real telemetry,
        // and overwriting it from a ping would make a reachable-but-struggling host look perfect.
        await _repository.updateConnectionState(
          server.id,
          'online',
          server.healthScore,
          rtt.inMilliseconds,
        );
        return;
      }

      final ssh = transport;
      if (ssh == null) {
        // Compatibility for transport-less tests/builds. Production always wires the configured
        // SSH fallback, so a direct failure there never becomes a verdict by itself.
        _probed.add(server.id);
        await _markOfflineUnlessSshSucceeded(server, evidenceGeneration, generation);
        return;
      }
      final creds = resolveCredentials(
        server,
        keys: await _repository.getAllKeys(),
        profiles: await _repository.getAllProfiles(),
      );
      if (!_workIsCurrent(generation)) return;
      final failure = await ssh.testConnection(creds);
      if (!_workIsCurrent(generation)) return;
      _probed.add(server.id);
      if (failure == null) {
        await Future.wait([
          _repository.updateConnectionState(
            server.id,
            'online',
            server.healthScore,
            stopwatch.elapsedMilliseconds,
          ),
          _repository.updateAuthState(server.id, 'ok', null),
        ]);
      } else if (!_mayMarkOffline(server.id, evidenceGeneration, generation)) {
        // A shell opened while this independent check was in flight. Do not replace its successful
        // authentication with the second connection's failure either.
        await _preserveInteractiveSuccess(server);
      } else if (sshFailureProvesEndpointUnreachable(failure)) {
        await _markOfflineUnlessSshSucceeded(server, evidenceGeneration, generation);
      } else {
        // Auth/host-key failures prove that an SSH server answered. Ambiguous transport errors do
        // not justify hiding the host from online-only screens or preventing a manual attempt.
        await Future.wait([
          _repository.updateConnectionState(
            server.id,
            'online',
            server.healthScore,
            stopwatch.elapsedMilliseconds,
          ),
          _repository.updateAuthState(server.id, 'failed', failure),
        ]);
      }
    } catch (_) {
      if (!_workIsCurrent(generation)) return;
      if (!_mayMarkOffline(server.id, evidenceGeneration, generation)) {
        await _preserveInteractiveSuccess(server).catchError((Object _) {});
        return;
      }
      // Failure to run the advisory checker says nothing about the host. Restore the previous state
      // rather than leaving a retried card stuck at "connecting" or inventing an offline verdict.
      await _repository
          .updateConnectionState(server.id, server.status, server.healthScore, server.lastLatency)
          .catchError((Object _) {});
    } finally {
      // Battery saver can invalidate a probe after its temporary "connecting" write. Restore the
      // previous state only if no newer probe or live shell has supplied stronger evidence; leaving
      // a host permanently "connecting" makes every tab wait on work that no longer exists.
      //
      // Deliberately not gated on this probe having been the one to write "connecting": a row left
      // that way by an earlier invalidated probe would otherwise stay stranded forever, which is
      // the "Checking host…" spinner that never resolves and never reports an error. Restoring is
      // skipped when the snapshot was itself "connecting", because then there is no earlier state
      // to go back to and inventing one would be a guess.
      if (!_workIsCurrent(generation) && !_disposed && server.status != 'connecting') {
        if (_liveSessionServers.contains(server.id) ||
            (_evidenceGeneration[server.id] ?? 0) != evidenceGeneration) {
          await _preserveInteractiveSuccess(server);
        } else {
          final current = await _repository.getServerById(server.id);
          if (current?.status == 'connecting') {
            await _repository.updateConnectionState(
              server.id,
              server.status,
              server.healthScore,
              server.lastLatency,
            );
          }
        }
      }
    }
  }

  bool _mayMarkOffline(int serverId, int evidenceGeneration, int generation) =>
      _workIsCurrent(generation) &&
      !_liveSessionServers.contains(serverId) &&
      (_evidenceGeneration[serverId] ?? 0) == evidenceGeneration;

  Future<void> _markOfflineUnlessSshSucceeded(
    Server server,
    int evidenceGeneration,
    int generation,
  ) async {
    if (!_workIsCurrent(generation)) return;
    if (!_mayMarkOffline(server.id, evidenceGeneration, generation)) {
      await _preserveInteractiveSuccess(server);
      return;
    }
    await _repository.updateConnectionState(server.id, 'offline', 0, 0);
    // Database writes yield. Reconcile once more in case a shell opened while the offline write was
    // being committed; the successful SSH result must be the final visible state.
    if (!_workIsCurrent(generation)) return;
    if (!_mayMarkOffline(server.id, evidenceGeneration, generation)) {
      await _preserveInteractiveSuccess(server);
    }
  }

  Future<void> _preserveInteractiveSuccess(Server server) => _repository.updateConnectionState(
    server.id,
    'online',
    server.healthScore,
    server.lastLatency,
  );

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
