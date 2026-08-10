import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/ssh_tunnel_manager.dart';

void main() {
  test(
    'SOCKS5 CONNECT preserves the domain and pipes both directions',
    () async {
      late SocksForwardTarget opened;
      final channel = _FakeSshSocket();
      final server = await SocksForwardServer.bind(
        bindHost: '127.0.0.1',
        bindPort: 0,
        openChannel: (target) async {
          opened = target;
          return channel;
        },
      );
      final socket = await Socket.connect('127.0.0.1', server.port);
      final reader = _ClientReader(socket);

      socket.add(const [5, 1, 0]);
      await socket.flush();
      expect(await reader.read(2), [5, 0]);

      const host = 'private.internal';
      socket.add([
        5,
        1,
        0,
        3,
        host.length,
        ...host.codeUnits,
        1,
        187, // 443
      ]);
      await socket.flush();
      expect(await reader.read(10), [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      expect(
        opened.host,
        host,
        reason: 'the remote side must resolve private DNS',
      );
      expect(opened.port, 443);

      socket.add(const [1, 2, 3]);
      await socket.flush();
      await _eventually(() => channel.received.length == 3);
      expect(channel.received.takeBytes(), [1, 2, 3]);

      channel.send(const [9, 8]);
      expect(await reader.read(2), [9, 8]);

      await socket.close();
      await reader.cancel();
      await server.close();
    },
  );

  test('SOCKS4 CONNECT accepts an IPv4 destination', () async {
    late SocksForwardTarget opened;
    final server = await SocksForwardServer.bind(
      bindHost: '127.0.0.1',
      bindPort: 0,
      openChannel: (target) async {
        opened = target;
        return _FakeSshSocket();
      },
    );
    final socket = await Socket.connect('127.0.0.1', server.port);
    final reader = _ClientReader(socket);

    socket.add(const [4, 1, 0, 80, 10, 20, 30, 40, 117, 0]);
    await socket.flush();

    expect(await reader.read(8), [0, 90, 0, 0, 0, 0, 0, 0]);
    expect(opened.host, '10.20.30.40');
    expect(opened.port, 80);

    await socket.close();
    await reader.cancel();
    await server.close();
  });

  test('SOCKS4a CONNECT sends the unresolved domain through SSH', () async {
    late SocksForwardTarget opened;
    final server = await SocksForwardServer.bind(
      bindHost: '127.0.0.1',
      bindPort: 0,
      openChannel: (target) async {
        opened = target;
        return _FakeSshSocket();
      },
    );
    final socket = await Socket.connect('127.0.0.1', server.port);
    final reader = _ClientReader(socket);
    const host = 'nas.lan';

    socket.add([
      4,
      1,
      0,
      22,
      0,
      0,
      0,
      1,
      0, // empty user id
      ...host.codeUnits,
      0,
    ]);
    await socket.flush();

    expect(await reader.read(8), [0, 90, 0, 0, 0, 0, 0, 0]);
    expect(opened.host, host);
    expect(opened.port, 22);

    await socket.close();
    await reader.cancel();
    await server.close();
  });

  test(
    'SOCKS5 refuses unsupported authentication without opening SSH',
    () async {
      var opens = 0;
      final server = await SocksForwardServer.bind(
        bindHost: '127.0.0.1',
        bindPort: 0,
        openChannel: (_) async {
          opens++;
          return _FakeSshSocket();
        },
      );
      final socket = await Socket.connect('127.0.0.1', server.port);
      final reader = _ClientReader(socket);

      socket.add(const [
        5,
        1,
        2,
      ]); // username/password only; dynamic forwards are NO AUTH
      await socket.flush();

      expect(await reader.read(2), [5, 255]);
      expect(opens, 0);

      await socket.close();
      await reader.cancel();
      await server.close();
    },
  );
}

Future<void> _eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FakeSshSocket implements SSHSocket {
  _FakeSshSocket() {
    _incoming.stream.listen(received.add);
  }

  final _outgoing = StreamController<Uint8List>();
  final _incoming = StreamController<List<int>>();
  final received = BytesBuilder(copy: true);
  bool _closed = false;

  void send(List<int> bytes) => _outgoing.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get stream => _outgoing.stream;

  @override
  StreamSink<List<int>> get sink => _incoming.sink;

  @override
  Future<void> get done => _incoming.done;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
    await _outgoing.close();
  }

  @override
  void destroy() {
    unawaited(close());
  }

  @override
  Future<void> flush() async {}
}

class _ClientReader {
  _ClientReader(Socket socket) {
    _subscription = socket.listen(
      _buffer.add,
      onError: (Object error) => _error = error,
      onDone: () => _done = true,
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = BytesBuilder(copy: true);
  Object? _error;
  bool _done = false;

  Future<List<int>> read(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (_buffer.length < count) {
      if (_error != null) fail('socket failed: $_error');
      if (_done) fail('socket closed before $count bytes arrived');
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $count bytes');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final all = _buffer.takeBytes();
    _buffer.add(all.sublist(count));
    return all.sublist(0, count);
  }

  Future<void> cancel() => _subscription.cancel();
}
