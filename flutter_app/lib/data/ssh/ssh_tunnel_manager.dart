import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
/// Dynamic forwarding accepts SOCKS4, SOCKS4a and SOCKS5 CONNECT, matching the Android app. Parsing
/// is bounded (15-second handshake, 1024-byte null-terminated fields) because this listener is an
/// attacker-reachable protocol whenever the user deliberately binds it beyond loopback.
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
  /// - `dynamic` (-D): a SOCKS4/4a/5 proxy on [bindHost]:[bindPort].
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
        return _LocalForward.bind(
          client,
          bindHost,
          bindPort,
          destHost,
          destPort,
        );
      case 'remote':
        return _RemoteForward.bind(
          client,
          bindHost,
          bindPort,
          destHost,
          destPort,
        );
      case 'dynamic':
        final forward = await SocksForwardServer.bind(
          bindHost: bindHost,
          bindPort: bindPort,
          openChannel: (target) => client.forwardLocal(
            target.host,
            target.port,
            localHost: target.originHost,
            localPort: target.originPort,
          ),
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
  _RemoteForward(
    this._client,
    this._forward,
    this._boundPort,
    this._destHost,
    this._destPort,
  ) {
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

/// Destination requested by a SOCKS client, plus the origin reported to the SSH server.
class SocksForwardTarget {
  const SocksForwardTarget({
    required this.host,
    required this.port,
    required this.originHost,
    required this.originPort,
  });

  final String host;
  final int port;
  final String originHost;
  final int originPort;
}

/// A bounded SOCKS4/4a/5 CONNECT listener.
///
/// Public so its wire behavior can be tested without constructing a real [SSHClient]. Production
/// supplies [SSHClient.forwardLocal] as [openChannel]; tests supply an in-memory [SSHSocket].
class SocksForwardServer {
  SocksForwardServer._(this._server, this._openChannel) {
    _subscription = _server.listen(_accept, onError: (_) {});
  }

  static const handshakeTimeout = Duration(seconds: 15);

  static Future<SocksForwardServer> bind({
    required String bindHost,
    required int bindPort,
    required Future<SSHSocket> Function(SocksForwardTarget target) openChannel,
  }) async {
    final server = await ServerSocket.bind(
      bindHost.trim().isEmpty ? '127.0.0.1' : bindHost,
      bindPort,
      shared: false,
    );
    return SocksForwardServer._(server, openChannel);
  }

  final ServerSocket _server;
  final Future<SSHSocket> Function(SocksForwardTarget target) _openChannel;
  late final StreamSubscription<Socket> _subscription;
  final Set<Socket> _clients = {};
  final Set<SSHSocket> _channels = {};
  bool _closed = false;

  int get port => _server.port;
  bool get isClosed => _closed;

  Future<void> _accept(Socket socket) async {
    _clients.add(socket);
    SSHSocket? channel;
    _SocketByteReader? reader;
    var version = 0;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketByteReader(socket);
      version = (await reader.read(1, handshakeTimeout)).single;
      final destination = switch (version) {
        4 => await _readSocks4(reader),
        5 => await _readSocks5(socket, reader),
        _ => null,
      };
      if (destination == null) return;

      final target = SocksForwardTarget(
        host: destination.$1,
        port: destination.$2,
        originHost: socket.remoteAddress.address,
        originPort: socket.remotePort,
      );
      try {
        channel = await _openChannel(target).timeout(handshakeTimeout);
        _channels.add(channel);
      } catch (_) {
        _writeFailure(socket, version);
        await socket.flush();
        return;
      }

      _writeSuccess(socket, version);
      await socket.flush();
      await _pipeReader(socket, reader, channel);
    } catch (_) {
      // A malformed/aborted handshake or unreachable destination affects only this connection.
    } finally {
      if (channel != null) {
        _channels.remove(channel);
        await channel.close().catchError((_) {});
      }
      _clients.remove(socket);
      await reader?.cancel().catchError((_) {});
      await socket.close().catchError((_) {});
    }
  }

  Future<(String, int)?> _readSocks5(
    Socket socket,
    _SocketByteReader reader,
  ) async {
    final methodCount = (await reader.read(1, handshakeTimeout)).single;
    if (methodCount == 0) {
      socket.add(const [5, 0xff]);
      await socket.flush();
      return null;
    }
    final methods = await reader.read(methodCount, handshakeTimeout);
    if (!methods.contains(0)) {
      socket.add(const [5, 0xff]);
      await socket.flush();
      return null;
    }
    socket.add(const [5, 0]);
    await socket.flush();

    final header = await reader.read(4, handshakeTimeout);
    if (header[0] != 5 || header[1] != 1 || header[2] != 0) {
      _writeFailure(socket, 5);
      await socket.flush();
      return null;
    }
    final host = switch (header[3]) {
      1 => InternetAddress.fromRawAddress(
        await reader.read(4, handshakeTimeout),
      ).address,
      3 => utf8.decode(
        await reader.read(
          (await reader.read(1, handshakeTimeout)).single,
          handshakeTimeout,
        ),
      ),
      4 => InternetAddress.fromRawAddress(
        await reader.read(16, handshakeTimeout),
      ).address,
      _ => null,
    };
    if (host == null || host.isEmpty) {
      _writeFailure(socket, 5);
      await socket.flush();
      return null;
    }
    return (host, await _readPort(reader));
  }

  Future<(String, int)?> _readSocks4(_SocketByteReader reader) async {
    if ((await reader.read(1, handshakeTimeout)).single != 1) return null;
    final port = await _readPort(reader);
    final address = await reader.read(4, handshakeTimeout);
    await reader.readNullTerminated(
      handshakeTimeout,
      maxBytes: 1024,
    ); // user id
    final isSocks4a =
        address[0] == 0 &&
        address[1] == 0 &&
        address[2] == 0 &&
        address[3] != 0;
    final host = isSocks4a
        ? await reader.readNullTerminated(handshakeTimeout, maxBytes: 1024)
        : InternetAddress.fromRawAddress(address).address;
    return host.isEmpty ? null : (host, port);
  }

  Future<int> _readPort(_SocketByteReader reader) async {
    final bytes = await reader.read(2, handshakeTimeout);
    return (bytes[0] << 8) | bytes[1];
  }

  static void _writeSuccess(Socket socket, int version) {
    socket.add(
      version == 5
          ? const [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]
          : const [0, 90, 0, 0, 0, 0, 0, 0],
    );
  }

  static void _writeFailure(Socket socket, int version) {
    socket.add(
      version == 5
          ? const [5, 5, 0, 1, 0, 0, 0, 0, 0, 0]
          : const [0, 91, 0, 0, 0, 0, 0, 0],
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close().catchError((_) => _server);
    for (final socket in _clients.toList()) {
      await socket.close().catchError((_) {});
    }
    for (final channel in _channels.toList()) {
      await channel.close().catchError((_) {});
    }
    _clients.clear();
    _channels.clear();
  }
}

/// `ssh -D`: local SOCKS4/4a/5 listener backed by one SSH direct-tcpip channel per request.
class _DynamicForward implements _ActiveTunnel {
  _DynamicForward(this._client, this._forward);

  final SSHClient _client;
  final SocksForwardServer _forward;
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

Future<void> _pipeReader(
  Socket socket,
  _SocketByteReader reader,
  SSHSocket channel,
) async {
  final fromRemote = channel.stream.listen(
    socket.add,
    onError: (_) {},
    onDone: () => socket.close().catchError((_) {}),
    cancelOnError: true,
  );
  try {
    await reader.release().forEach(channel.sink.add);
  } catch (_) {
    // Client went away mid-stream.
  } finally {
    await fromRemote.cancel();
  }
}

/// Precise, bounded reads from a socket whose subscription must survive into the forwarded stream.
class _SocketByteReader {
  _SocketByteReader(Socket socket) {
    _subscription = socket.listen(
      _buffer.add,
      onError: (Object error) => _error ??= error,
      onDone: () => _done = true,
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: true);
  Object? _error;
  bool _done = false;
  bool _released = false;

  Future<Uint8List> read(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      if (_error != null) {
        throw SocketException('SOCKS connection failed: $_error');
      }
      if (_done) {
        throw const SocketException(
          'SOCKS client closed during the handshake.',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const SocketException(
          'SOCKS client did not finish the handshake in time.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final all = _buffer.takeBytes();
    _buffer.add(all.sublist(count));
    return Uint8List.sublistView(all, 0, count);
  }

  Future<String> readNullTerminated(
    Duration timeout, {
    required int maxBytes,
  }) async {
    final bytes = <int>[];
    while (bytes.length < maxBytes) {
      final next = (await read(1, timeout)).single;
      if (next == 0) return String.fromCharCodes(bytes);
      bytes.add(next);
    }
    throw const SocketException('SOCKS field exceeds 1024 bytes.');
  }

  Stream<Uint8List> release() {
    if (_released) throw StateError('SOCKS socket reader already released.');
    _released = true;
    final controller = StreamController<Uint8List>();
    final surplus = _buffer.takeBytes();
    if (surplus.isNotEmpty) controller.add(surplus);
    if (_error != null) {
      controller.addError(_error!);
    } else if (_done) {
      unawaited(controller.close());
    }
    _subscription
      ..onData(controller.add)
      ..onError(controller.addError)
      ..onDone(controller.close);
    return controller.stream;
  }

  Future<void> cancel() => _released ? Future.value() : _subscription.cancel();
}
