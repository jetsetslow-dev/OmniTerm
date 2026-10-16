/// Reaching a host through an HTTP CONNECT or SOCKS5 proxy.
///
/// **The target's hostname is sent to the proxy unresolved, deliberately.** A proxy exists precisely
/// because the target is not reachable — often not even *nameable* — from where the app is running.
/// Resolving it locally first is the classic mistake: it fails with a DNS error on exactly the hosts
/// the proxy was configured to reach, and on a split-horizon network it can silently resolve to the
/// *wrong* machine. SOCKS5 has a domain-name address type for this, and HTTP CONNECT takes a host
/// string; both let the proxy do the lookup on the network where the name means something.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class ProxyException implements Exception {
  ProxyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Opens a TCP connection to [host]:[port] **through** the proxy at [proxyHost]:[proxyPort].
Future<SSHSocket> connectThroughProxy({
  required String type,
  required String proxyHost,
  required int proxyPort,
  required String host,
  required int port,
  String username = '',
  String password = '',
  Duration timeout = const Duration(seconds: 15),
}) async {
  final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
  // One subscription for the whole life of the connection. `Socket` is single-subscription, so a
  // reader that listened for the handshake and then cancelled would leave a stream nobody can
  // listen to again — and any bytes that arrived in the same packet as the proxy's reply would be
  // lost with it, which is exactly the start of the SSH banner.
  final reader = _SocketReader(socket);
  try {
    switch (type.toLowerCase()) {
      case 'socks5':
        await _socks5Handshake(socket, reader, host, port, username, password, timeout);
      case 'http':
        await _httpConnect(socket, reader, host, port, username, password, timeout);
      default:
        throw ProxyException('Unsupported proxy type "$type".');
    }
  } catch (_) {
    socket.destroy();
    rethrow;
  }
  return _ProxiedSocket(socket, reader);
}

// ── SOCKS5 (RFC 1928 / RFC 1929) ──────────────────────────────────────────────

const _socksVersion = 0x05;
const _cmdConnect = 0x01;
const _addrDomain = 0x03;
const _authNone = 0x00;
const _authUserPass = 0x02;

Future<void> _socks5Handshake(
  Socket socket,
  _SocketReader reader,
  String host,
  int port,
  String username,
  String password,
  Duration timeout,
) async {
  // Offer username/password only when we actually have one: advertising it to a proxy that does
  // not need it invites a challenge we would then have to answer with credentials the user
  // supplied for something else.
  final methods = username.isEmpty ? [_authNone] : [_authNone, _authUserPass];
  socket.add(Uint8List.fromList([_socksVersion, methods.length, ...methods]));
  await socket.flush();

  final greeting = await reader.read(2, timeout);
  if (greeting[0] != _socksVersion) {
    throw ProxyException('The proxy did not answer as SOCKS5.');
  }
  switch (greeting[1]) {
    case _authNone:
      break;
    case _authUserPass:
      if (username.isEmpty) {
        throw ProxyException('The SOCKS5 proxy requires a username and password.');
      }
      await _socks5Authenticate(socket, reader, username, password, timeout);
    case 0xFF:
      throw ProxyException('The SOCKS5 proxy rejected every authentication method offered.');
    default:
      throw ProxyException('The SOCKS5 proxy asked for an unsupported authentication method.');
  }

  // The domain-name address type: the proxy resolves, not us.
  final name = utf8.encode(host);
  if (name.length > 255) throw ProxyException('That hostname is too long for SOCKS5.');
  socket.add(
    Uint8List.fromList([
      _socksVersion,
      _cmdConnect,
      0x00,
      _addrDomain,
      name.length,
      ...name,
      (port >> 8) & 0xFF,
      port & 0xFF,
    ]),
  );
  await socket.flush();

  final reply = await reader.read(4, timeout);
  if (reply[1] != 0x00) throw ProxyException(_socksError(reply[1], host, port));

  // The bound address comes back in the reply and must be consumed, or its bytes would be read
  // as the first bytes of the SSH banner.
  switch (reply[3]) {
    case 0x01:
      await reader.read(4 + 2, timeout);
    case _addrDomain:
      final length = (await reader.read(1, timeout))[0];
      await reader.read(length + 2, timeout);
    case 0x04:
      await reader.read(16 + 2, timeout);
    default:
      throw ProxyException('The SOCKS5 proxy replied with an unknown address type.');
  }
}

Future<void> _socks5Authenticate(
  Socket socket,
  _SocketReader reader,
  String username,
  String password,
  Duration timeout,
) async {
  final user = utf8.encode(username);
  final pass = utf8.encode(password);
  if (user.length > 255 || pass.length > 255) {
    throw ProxyException('The SOCKS5 username or password is too long.');
  }
  socket.add(Uint8List.fromList([0x01, user.length, ...user, pass.length, ...pass]));
  await socket.flush();
  final reply = await reader.read(2, timeout);
  if (reply[1] != 0x00) {
    throw ProxyException('The SOCKS5 proxy rejected those credentials.');
  }
}

String _socksError(int code, String host, int port) => switch (code) {
  0x01 => 'The SOCKS5 proxy failed while connecting to $host:$port.',
  0x02 => 'The SOCKS5 proxy is not allowed to reach $host:$port.',
  0x03 => 'The SOCKS5 proxy reported the network to $host is unreachable.',
  0x04 => 'The SOCKS5 proxy reported $host is unreachable.',
  0x05 => '$host:$port refused the connection through the SOCKS5 proxy.',
  0x06 => 'The connection to $host:$port through the SOCKS5 proxy timed out.',
  0x07 => 'The SOCKS5 proxy does not support this kind of connection.',
  0x08 => 'The SOCKS5 proxy does not support that address type.',
  _ => 'The SOCKS5 proxy refused the connection to $host:$port (code $code).',
};

// ── HTTP CONNECT (RFC 7231 §4.3.6) ────────────────────────────────────────────

Future<void> _httpConnect(
  Socket socket,
  _SocketReader reader,
  String host,
  int port,
  String username,
  String password,
  Duration timeout,
) async {
  {
    final target = '$host:$port';
    final request = StringBuffer()
      ..write('CONNECT $target HTTP/1.1\r\n')
      ..write('Host: $target\r\n');
    if (username.isNotEmpty) {
      final token = base64.encode(utf8.encode('$username:$password'));
      request.write('Proxy-Authorization: Basic $token\r\n');
    }
    request.write('\r\n');
    socket.add(utf8.encode(request.toString()));
    await socket.flush();

    // Read exactly to the end of the headers and no further: anything after them is already the
    // tunnelled stream, and swallowing a byte of it corrupts the SSH banner.
    final header = await reader.readUntil('\r\n\r\n', timeout);
    final statusLine = header.split('\r\n').first;
    final parts = statusLine.split(' ');
    final status = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (status == null) {
      throw ProxyException('The proxy did not answer with an HTTP status line.');
    }
    if (status == 407) {
      throw ProxyException('The HTTP proxy requires credentials, or rejected the ones given.');
    }
    if (status < 200 || status > 299) {
      throw ProxyException('The HTTP proxy refused to connect to $target ($statusLine).');
    }
  }
}

// ── plumbing ──────────────────────────────────────────────────────────────────

/// Reads a precise number of bytes from a socket during the handshake, then hands the live stream
/// back untouched.
///
/// A single subscription is taken for the whole handshake and any surplus is kept, because the
/// proxy's reply and the first bytes of the tunnelled stream can arrive in one packet — a reader
/// that over-read and discarded would eat the start of the SSH banner.
class _SocketReader {
  _SocketReader(this._socket) {
    _subscription = _socket.listen(
      _buffer.add,
      onError: (Object e) => _error ??= e,
      onDone: () => _done = true,
      cancelOnError: false,
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: true);
  Object? _error;
  bool _done = false;

  Future<Uint8List> read(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      if (_error != null) throw ProxyException('The proxy connection failed: $_error');
      if (_done) throw ProxyException('The proxy closed the connection during the handshake.');
      if (DateTime.now().isAfter(deadline)) {
        throw ProxyException('The proxy did not answer in time.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final all = _buffer.takeBytes();
    _buffer.add(all.sublist(count));
    return Uint8List.sublistView(all, 0, count);
  }

  Future<String> readUntil(String marker, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    final bytes = utf8.encode(marker);
    while (true) {
      final all = _buffer.takeBytes();
      _buffer.add(all);
      final at = _indexOf(all, bytes);
      if (at >= 0) {
        final consumed = at + bytes.length;
        return utf8.decode(await read(consumed, timeout), allowMalformed: true);
      }
      if (_error != null) throw ProxyException('The proxy connection failed: $_error');
      if (_done) throw ProxyException('The proxy closed the connection during the handshake.');
      if (DateTime.now().isAfter(deadline)) {
        throw ProxyException('The proxy did not answer in time.');
      }
      // A proxy that answers with an unbounded header stream must not be able to exhaust memory.
      if (all.length > 64 * 1024) {
        throw ProxyException('The proxy sent an implausibly large response.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  static int _indexOf(List<int> haystack, List<int> needle) {
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// Hands the live connection on: whatever arrived after the handshake is replayed first, then
  /// everything the socket produces from here.
  ///
  /// The subscription is *kept*, not cancelled — `Socket` is single-subscription, so cancelling
  /// would leave dartssh2 with a stream it cannot listen to.
  Stream<Uint8List> release() {
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
}

/// The tunnelled connection, as dartssh2 wants it.
class _ProxiedSocket implements SSHSocket {
  _ProxiedSocket(this._socket, _SocketReader reader) : stream = reader.release();

  final Socket _socket;

  @override
  final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}
