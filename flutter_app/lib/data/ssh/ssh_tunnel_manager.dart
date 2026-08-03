import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'async_lock.dart';
import 'ssh_transport.dart';
import 'tunnel_generation.dart';

/// Owns the live SSH connections backing user-defined port-forwarding tunnels
/// (`ssh -L` / `-R` / `-D`). Ported from `data/ssh/SshTunnelManager.kt`.
///
/// Each active tunnel keeps its **own dedicated, un-pooled connection** for as long as the tunnel is
/// up. A pooled connection would be reclaimed while idle and silently drop the forward — the tunnel
/// would appear running while carrying nothing.
///
/// ## The big simplification
///
/// JSch does not implement `ssh -D`: its string overload parses an OpenSSH *local-forward*
/// specification, so a dynamic request always threw. The Kotlin therefore hand-wrote a complete
/// SOCKS4 / SOCKS4a / SOCKS5 proxy — roughly 150 lines of byte-level protocol parsing. dartssh2
/// implements dynamic forwarding natively, so all of that is deleted.
///
/// That is a security improvement as well as a size one (requirement 12): hand-rolled parsing of an
/// attacker-reachable wire protocol is exactly the code most worth not owning.
///
/// **Parity note:** dartssh2's dynamic forward is **SOCKS5 only** (NO AUTH, CONNECT), whereas the
/// Kotlin also accepted SOCKS4 and SOCKS4a. See MIGRATION.md §18.
class SshTunnelManager {
  SshTunnelManager(this._connect);

  /// Opens a dedicated connection for a tunnel. Injected rather than built here so this class owns
  /// no connection policy — and so tests can drive it without a socket.
  final Future<SSHClient> Function(SshCredentials creds) _connect;

  final Map<int, _ActiveTunnel> _active = {};
  final Map<int, AsyncLock> _locks = {};
  final Map<int, TunnelGeneration> _generations = {};

  /// True when the tunnel is up. A tunnel whose connection has died is reaped here, so the UI's
  /// "running" indicator can never outlive the actual forward.
  bool isActive(int tunnelId) {
    final tunnel = _active[tunnelId];
    if (tunnel == null) return false;
    if (tunnel.isAlive) return true;
    if (identical(_active[tunnelId], tunnel)) _active.remove(tunnelId);
    unawaited(tunnel.disconnect());
    return false;
  }

  Set<int> activeIds() => _active.keys.where(isActive).toSet();

  /// The actual local port a running tunnel bound (relevant when the request asked for port 0).
  int? boundPort(int tunnelId) => _active[tunnelId]?.boundPort;

  /// Bring up tunnel [id] over [creds].
  ///
  /// - `local` (-L): listen on [bindHost]:[bindPort], forward to [destHost]:[destPort] via the remote.
  /// - `remote` (-R): the remote listens on [bindPort] and forwards back to [destHost]:[destPort].
  /// - `dynamic` (-D): a SOCKS5 proxy on [bindHost]:[bindPort].
  ///
  /// Idempotent: starting an already-active tunnel is a no-op returning its bound port. Throws with
  /// a cleaned-up connection on connect/bind failure. Returns the bound local port, which is what
  /// the caller needs when [bindPort] was 0.
  Future<int> start({
    required int id,
    required SshCredentials creds,
    required String kind,
    required String bindHost,
    required int bindPort,
    required String destHost,
    required int destPort,
  }) {
    final generation = _generations.putIfAbsent(id, TunnelGeneration.new);
    final expected = generation.snapshot();
    final lock = _locks.putIfAbsent(id, AsyncLock.new);

    return lock.synchronized(() async {
      final existing = _active[id];
      if (existing != null && existing.isAlive) return existing.boundPort;
      if (existing != null) {
        _active.remove(id);
        await existing.disconnect();
      }

      SSHClient? client;
      _ActiveTunnel? built;
      try {
        client = await _connect(creds);
        built = await _openForward(
          client: client,
          kind: kind,
          bindHost: bindHost,
          bindPort: bindPort,
          destHost: destHost,
          destPort: destPort,
        );

        final tunnel = built;
        final published = generation.publishIfCurrent(
          expected: expected,
          publish: () => _active[id] = tunnel,
          rollback: () {
            if (identical(_active[id], tunnel)) _active.remove(id);
          },
        );
        if (!published) {
          // stop() landed while we were dialling. Tear down rather than leaving a tunnel alive
          // after stop() has already returned to its caller.
          await tunnel.disconnect();
          throw SshConnectException('Tunnel was stopped while starting');
        }
        return tunnel.boundPort;
      } catch (e) {
        if (built != null) {
          await built.disconnect();
        } else {
          client?.close();
        }
        if (e is SshConnectException) rethrow;
        throw SshConnectException('Failed to start tunnel: $e', e);
      }
    });
  }

  Future<_ActiveTunnel> _openForward({
    required SSHClient client,
    required String kind,
    required String bindHost,
    required int bindPort,
    required String destHost,
    required int destPort,
  }) async {
    switch (kind) {
      case 'local':
        return _LocalForward.bind(client, bindHost, bindPort, destHost, destPort);
      case 'remote':
        return _RemoteForward.bind(client, bindHost, bindPort, destHost, destPort);
      case 'dynamic':
        final forward = await client.forwardDynamic(
          bindHost: bindHost,
          bindPort: bindPort == 0 ? null : bindPort,
        );
        return _DynamicForward(client, forward);
      default:
        throw ArgumentError('Unsupported tunnel kind: $kind');
    }
  }

  /// Tear a tunnel down. Safe to call when it isn't running.
  ///
  /// Deliberately does **not** take the per-tunnel lock: stopping must not queue behind a start that
  /// is hung dialling an unreachable host. The generation token is what makes that safe — an
  /// in-flight start sees its generation invalidated and discards itself.
  Future<void> stop(int id) async {
    _generations.putIfAbsent(id, TunnelGeneration.new).invalidate();
    final tunnel = _active.remove(id);
    if (tunnel == null) return;
    await tunnel.disconnect();
  }

  /// Stop every running tunnel (app teardown / logout).
  Future<void> stopAll() async {
    final ids = {..._active.keys, ..._generations.keys};
    for (final id in ids) {
      await stop(id);
    }
  }
}

/// One running tunnel.
abstract class _ActiveTunnel {
  int get boundPort;

  bool get isAlive;

  Future<void> disconnect();
}

/// `ssh -L`: a local listener that opens one forwarded channel per accepted connection.
///
/// dartssh2's `forwardLocal` opens a single channel; it does not bind a listening socket, so the
/// accept loop lives here. Unlike the Kotlin's SOCKS proxy this parses nothing — it only pipes
/// bytes, which is why it is safe to own.
class _LocalForward implements _ActiveTunnel {
  _LocalForward(this._client, this._server, this._destHost, this._destPort) {
    _subscription = _server.listen(_accept, onError: (_) {});
  }

  static Future<_LocalForward> bind(
    SSHClient client,
    String bindHost,
    int bindPort,
    String destHost,
    int destPort,
  ) async {
    final server = await ServerSocket.bind(
      bindHost.trim().isEmpty ? '127.0.0.1' : bindHost,
      bindPort,
      shared: false,
    );
    return _LocalForward(client, server, destHost, destPort);
  }

  final SSHClient _client;
  final ServerSocket _server;
  final String _destHost;
  final int _destPort;
  late final StreamSubscription<Socket> _subscription;
  final Set<Socket> _clients = {};
  bool _closed = false;

  @override
  int get boundPort => _server.port;

  @override
  bool get isAlive => !_closed && !_client.isClosed;

  Future<void> _accept(Socket socket) async {
    _clients.add(socket);
    try {
      final channel = await _client.forwardLocal(_destHost, _destPort);
      await _pipe(socket, channel);
    } catch (_) {
      // One failed connection must not take the listener down: an unreachable destination affects
      // only that client.
    } finally {
      _clients.remove(socket);
      await socket.close().catchError((_) {});
    }
  }

  @override
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    // ServerSocket.close() returns the socket, so catchError must too; ignoring is fine
    // because a close failure on teardown has nowhere useful to go.
    await _server.close().catchError((_) => _server);
    for (final socket in _clients.toList()) {
      await socket.close().catchError((_) {});
    }
    _clients.clear();
    _client.close();
  }
}

/// `ssh -R`: the remote listens, and each inbound connection is piped to a local destination.
class _RemoteForward implements _ActiveTunnel {
  _RemoteForward(this._client, this._forward, this._boundPort, this._destHost, this._destPort) {
    _subscription = _forward.connections.listen(_accept, onError: (_) {});
  }

  static Future<_RemoteForward> bind(
    SSHClient client,
    String bindHost,
    int bindPort,
    String destHost,
    int destPort,
  ) async {
    final forward = await client.forwardRemote(
      host: bindHost.trim().isEmpty ? null : bindHost,
      port: bindPort,
    );
    if (forward == null) {
      throw SshConnectException(
        'The server refused to listen on port $bindPort (remote forwarding may be disabled, '
        'or the port is in use or privileged).',
      );
    }
    return _RemoteForward(client, forward, forward.port, destHost, destPort);
  }

  final SSHClient _client;
  final SSHRemoteForward _forward;
  final int _boundPort;
  final String _destHost;
  final int _destPort;
  late final StreamSubscription<SSHForwardChannel> _subscription;
  final Set<Socket> _sockets = {};
  bool _closed = false;

  @override
  int get boundPort => _boundPort;

  @override
  bool get isAlive => !_closed && !_client.isClosed;

  Future<void> _accept(SSHForwardChannel channel) async {
    Socket? socket;
    try {
      socket = await Socket.connect(_destHost, _destPort);
      _sockets.add(socket);
      await _pipe(socket, channel);
    } catch (_) {
      await channel.close().catchError((_) {});
    } finally {
      if (socket != null) {
        _sockets.remove(socket);
        await socket.close().catchError((_) {});
      }
    }
  }

  @override
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    for (final socket in _sockets.toList()) {
      await socket.close().catchError((_) {});
    }
    _sockets.clear();
    _client.close();
  }
}

/// `ssh -D`: dartssh2's native SOCKS5 forward. No protocol parsing of our own.
class _DynamicForward implements _ActiveTunnel {
  _DynamicForward(this._client, this._forward);

  final SSHClient _client;
  final SSHDynamicForward _forward;
  bool _closed = false;

  @override
  int get boundPort => _forward.port;

  @override
  bool get isAlive => !_closed && !_client.isClosed;

  @override
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    await _forward.close();
    _client.close();
  }
}

/// Pumps bytes both ways until either side closes.
///
/// Centralised (requirement 11) because both -L and -R need exactly this, and a second copy is how
/// one direction quietly stops being closed on teardown.
Future<void> _pipe(Socket socket, SSHForwardChannel channel) async {
  final fromRemote = channel.stream.listen(
    socket.add,
    onError: (_) {},
    onDone: () => socket.close().catchError((_) {}),
    cancelOnError: true,
  );
  try {
    await socket.forEach(channel.sink.add);
  } catch (_) {
    // Client went away mid-stream.
  } finally {
    await fromRemote.cancel();
    await channel.close().catchError((_) {});
  }
}
