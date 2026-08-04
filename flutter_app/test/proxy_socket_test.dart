import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/proxy_socket.dart';

/// A stand-in proxy bound to the loopback interface.
///
/// Its own server, on its own ephemeral port — nothing here depends on the machine's network, a DNS
/// server, or anything the dev box happens to be running.
class _FakeProxy {
  _FakeProxy(this._handle);

  final Future<void> Function(Socket socket, _FakeProxy proxy) _handle;

  late final ServerSocket _server;

  /// Everything the client sent during the handshake, for assertions.
  final BytesBuilder received = BytesBuilder(copy: true);

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) => unawaited(_handle(socket, this)));
  }

  Future<void> stop() => _server.close();

  String get receivedText => utf8.decode(received.toBytes(), allowMalformed: true);
}

void main() {
  late _FakeProxy proxy;

  tearDown(() => proxy.stop());

  Future<Uint8List> firstChunk(Stream<Uint8List> stream) =>
      stream.first.timeout(const Duration(seconds: 5));

  group('SOCKS5', () {
    /// A proxy that completes the handshake and then echoes a banner.
    Future<void> wellBehaved(Socket socket, _FakeProxy proxy) async {
      var stage = 0;
      socket.listen((data) {
        proxy.received.add(data);
        if (stage == 0) {
          socket.add([0x05, 0x00]); // no auth
          stage = 1;
        } else if (stage == 1) {
          // Success, bound to 0.0.0.0:0 — an IPv4 reply the client must consume in full.
          socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
          socket.add(utf8.encode('SSH-2.0-Fake\r\n'));
          stage = 2;
        }
      });
    }

    test('the hostname is sent to the proxy unresolved', () async {
      // The whole point: a proxy exists because the target is not reachable — often not even
      // nameable — from here. Resolving locally fails on exactly those hosts.
      proxy = _FakeProxy(wellBehaved);
      await proxy.start();

      final socket = await connectThroughProxy(
        type: 'socks5',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'internal-only.invalid',
        port: 2222,
      );
      await firstChunk(socket.stream);

      expect(proxy.receivedText, contains('internal-only.invalid'));
      // 0x03 is the domain-name address type; 0x01 would be a resolved IPv4 address.
      expect(proxy.received.toBytes(), contains(0x03));
      await socket.close();
    });

    test('bytes arriving with the reply are not swallowed', () async {
      // The proxy's reply and the first bytes of the SSH banner routinely land in one packet. A
      // handshake reader that over-read and discarded would eat the start of the banner.
      proxy = _FakeProxy(wellBehaved);
      await proxy.start();

      final socket = await connectThroughProxy(
        type: 'socks5',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'host.invalid',
        port: 22,
      );

      expect(utf8.decode(await firstChunk(socket.stream)), startsWith('SSH-2.0-Fake'));
      await socket.close();
    });

    test('credentials are offered only when there are some', () async {
      // Advertising username/password to a proxy that does not need it invites a challenge we would
      // then answer with credentials meant for something else.
      proxy = _FakeProxy(wellBehaved);
      await proxy.start();

      final socket = await connectThroughProxy(
        type: 'socks5',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'h.invalid',
        port: 22,
      );
      await firstChunk(socket.stream);

      // Greeting: version, method count, methods. One method offered, and it is "no auth".
      final greeting = proxy.received.toBytes();
      expect(greeting[0], 0x05);
      expect(greeting[1], 1, reason: 'only NO AUTH offered');
      expect(greeting[2], 0x00);
      await socket.close();
    });

    test('username and password authentication is performed when asked for', () async {
      proxy = _FakeProxy((socket, proxy) async {
        var stage = 0;
        socket.listen((data) {
          proxy.received.add(data);
          switch (stage) {
            case 0:
              socket.add([0x05, 0x02]); // demand username/password
              stage = 1;
            case 1:
              socket.add([0x01, 0x00]); // accepted
              stage = 2;
            case 2:
              socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
              socket.add(utf8.encode('SSH-2.0-Fake\r\n'));
              stage = 3;
          }
        });
      });
      await proxy.start();

      final socket = await connectThroughProxy(
        type: 'socks5',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'h.invalid',
        port: 22,
        username: 'sam',
        password: 'hunter2',
      );
      await firstChunk(socket.stream);

      expect(proxy.receivedText, contains('sam'));
      expect(proxy.receivedText, contains('hunter2'));
      await socket.close();
    });

    test('a refusal is reported in the proxy\'s own terms', () async {
      proxy = _FakeProxy((socket, proxy) async {
        var stage = 0;
        socket.listen((data) {
          if (stage == 0) {
            socket.add([0x05, 0x00]);
            stage = 1;
          } else {
            socket.add([0x05, 0x02, 0x00, 0x01, 0, 0, 0, 0, 0, 0]); // 0x02 = not allowed
          }
        });
      });
      await proxy.start();

      await expectLater(
        connectThroughProxy(
          type: 'socks5',
          proxyHost: '127.0.0.1',
          proxyPort: proxy.port,
          host: 'forbidden.invalid',
          port: 22,
        ),
        throwsA(isA<ProxyException>()
            .having((e) => e.message, 'message', contains('not allowed'))),
      );
    });

    test('a proxy that is not SOCKS5 says so rather than hanging', () async {
      proxy = _FakeProxy((socket, proxy) async {
        socket.listen((_) => socket.add(utf8.encode('HTTP/1.1 400 Bad Request\r\n\r\n')));
      });
      await proxy.start();

      await expectLater(
        connectThroughProxy(
          type: 'socks5',
          proxyHost: '127.0.0.1',
          proxyPort: proxy.port,
          host: 'h.invalid',
          port: 22,
        ),
        throwsA(isA<ProxyException>()
            .having((e) => e.message, 'message', contains('did not answer as SOCKS5'))),
      );
    });
  });

  group('HTTP CONNECT', () {
    test('the target is named in CONNECT, unresolved', () async {
      proxy = _FakeProxy((socket, proxy) async {
        socket.listen((data) {
          proxy.received.add(data);
          socket.add(utf8.encode('HTTP/1.1 200 Connection established\r\n\r\nSSH-2.0-Fake\r\n'));
        });
      });
      await proxy.start();

      final socket = await connectThroughProxy(
        type: 'http',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'internal-only.invalid',
        port: 2222,
      );

      expect(proxy.receivedText, contains('CONNECT internal-only.invalid:2222'));
      // Anything after the blank line is already the tunnel; swallowing a byte corrupts the banner.
      expect(utf8.decode(await firstChunk(socket.stream)), startsWith('SSH-2.0-Fake'));
      await socket.close();
    });

    test('credentials go in Proxy-Authorization, and only when present', () async {
      proxy = _FakeProxy((socket, proxy) async {
        socket.listen((data) {
          proxy.received.add(data);
          socket.add(utf8.encode('HTTP/1.1 200 OK\r\n\r\nX'));
        });
      });
      await proxy.start();

      final socket = await connectThroughProxy(
        type: 'http',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'h.invalid',
        port: 22,
        username: 'sam',
        password: 'hunter2',
      );
      await firstChunk(socket.stream);

      expect(proxy.receivedText, contains('Proxy-Authorization: Basic '));
      expect(
        proxy.receivedText,
        contains(base64.encode(utf8.encode('sam:hunter2'))),
      );
      // The password must not appear in the clear anywhere in the request.
      expect(proxy.receivedText, isNot(contains('hunter2')));
      await socket.close();
    });

    test('407 is reported as a credentials problem, not a generic failure', () async {
      proxy = _FakeProxy((socket, proxy) async {
        socket.listen((_) => socket.add(utf8.encode('HTTP/1.1 407 Proxy Auth Required\r\n\r\n')));
      });
      await proxy.start();

      await expectLater(
        connectThroughProxy(
          type: 'http',
          proxyHost: '127.0.0.1',
          proxyPort: proxy.port,
          host: 'h.invalid',
          port: 22,
        ),
        throwsA(isA<ProxyException>()
            .having((e) => e.message, 'message', contains('requires credentials'))),
      );
    });

    test('a refusal quotes the status line', () async {
      proxy = _FakeProxy((socket, proxy) async {
        socket.listen((_) => socket.add(utf8.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n')));
      });
      await proxy.start();

      await expectLater(
        connectThroughProxy(
          type: 'http',
          proxyHost: '127.0.0.1',
          proxyPort: proxy.port,
          host: 'h.invalid',
          port: 22,
        ),
        throwsA(isA<ProxyException>()
            .having((e) => e.message, 'message', contains('502'))),
      );
    });
  });

  test('an unknown proxy type is refused rather than silently bypassed', () async {
    // Connecting directly when a proxy was configured is the failure this whole file exists to
    // stop: it sends traffic down a route the user did not choose.
    proxy = _FakeProxy((socket, proxy) async {});
    await proxy.start();

    await expectLater(
      connectThroughProxy(
        type: 'gopher',
        proxyHost: '127.0.0.1',
        proxyPort: proxy.port,
        host: 'h.invalid',
        port: 22,
      ),
      throwsA(isA<ProxyException>()),
    );
  });
}
