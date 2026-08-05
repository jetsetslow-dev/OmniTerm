import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/whois.dart';

/// One WHOIS query over TCP port 43, ported from `queryWhoisServer` in `ui/AppViewModel.kt`.
///
/// An interface rather than a bare function so the view model can be tested without the network,
/// and so a platform without raw sockets can supply its own (or none, which the screen reports).
abstract interface class WhoisClient {
  /// Sends [target] to [server] and returns everything it said before closing.
  Future<String> query(String server, String target);
}

/// The real thing: connect, write one line, read until the server hangs up.
class SocketWhoisClient implements WhoisClient {
  const SocketWhoisClient({
    this.connectTimeout = const Duration(seconds: 6),
    this.readTimeout = const Duration(seconds: 10),
  });

  final Duration connectTimeout;

  /// How long to wait for the whole reply. WHOIS has no length header and no terminator — the
  /// server closing the socket *is* the end of the message — so a server that accepts the
  /// connection and then says nothing would otherwise hold the screen forever.
  final Duration readTimeout;

  @override
  Future<String> query(String server, String target) async {
    final host = cleanWhoisServerHost(server);
    if (!isUsableWhoisHost(host)) {
      throw const WhoisException('That does not look like a WHOIS server address.');
    }

    Socket? socket;
    try {
      socket = await Socket.connect(host, 43, timeout: connectTimeout);
      socket.write(whoisRequestLine(target));
      await socket.flush();

      final bytes = <int>[];
      await socket
          .forEach(bytes.addAll)
          .timeout(
            readTimeout,
            onTimeout: () => throw const WhoisException('The server stopped responding.'),
          );

      // allowMalformed: registry replies are mostly ASCII but carry latin-1 names often enough that
      // throwing on one bad byte would lose an otherwise complete record.
      return utf8.decode(bytes, allowMalformed: true);
    } on SocketException catch (e) {
      throw WhoisException(e.osError?.message ?? e.message);
    } on TimeoutException {
      throw const WhoisException('The server did not answer in time.');
    } finally {
      socket?.destroy();
    }
  }
}

/// A WHOIS lookup that could not be completed, with a sentence fit to show the user.
class WhoisException implements Exception {
  const WhoisException(this.message);

  final String message;

  @override
  String toString() => message;
}
