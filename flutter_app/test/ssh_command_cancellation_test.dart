import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

void main() {
  test('cancellation returns while a peer is still withholding its SSH greeting', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    listener.listen((socket) => accepted.complete(socket));
    final cancellation = SshCancellationToken();
    final transport = DartSshTransport(SshHostKeyTrust(InMemoryHostKeyStore()));
    Socket? peer;
    final chunks = <String>[];
    try {
      final result = transport.execStream(
        SshCredentials(host: '127.0.0.1', port: listener.port, username: 'fixture'),
        'printf should-not-run',
        cancellation: cancellation,
        onChunk: (chunk) async => chunks.add(chunk),
      );
      peer = await accepted.future.timeout(const Duration(seconds: 3));
      cancellation.cancel();
      expect(await result.timeout(const Duration(seconds: 1)), 'Cancelled');
      expect(chunks, isEmpty);
      // Ending the deliberately stalled peer also exercises late connection-error consumption.
    } finally {
      transport.shutdown();
      peer?.destroy();
      await cancellation.close();
      await listener.close();
    }
  });

  test('an already cancelled streaming command never connects to the host', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    listener.listen((socket) {
      connections++;
      socket.destroy();
    });
    final cancellation = SshCancellationToken()..cancel();
    final transport = DartSshTransport(SshHostKeyTrust(InMemoryHostKeyStore()));
    try {
      final result = await transport
          .execStream(
            SshCredentials(host: '127.0.0.1', port: listener.port, username: 'fixture'),
            'printf should-not-run',
            cancellation: cancellation,
            onChunk: (_) async {},
          )
          .timeout(const Duration(seconds: 3));
      expect(result, 'Cancelled');
      expect(connections, 0, reason: 'cancelled work must not open or wait for a connection');
    } finally {
      transport.shutdown();
      await cancellation.close();
      await listener.close();
    }
  });
}
