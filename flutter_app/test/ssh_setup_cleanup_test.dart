import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_private_key.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

void main() {
  for (final bastion in [false, true]) {
    test('invalid ${bastion ? 'bastion' : 'target'} key releases its setup socket', () async {
      // A repository-owned loopback listener: no SSH daemon, keys or personal hosts required.
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      final accepted = Completer<void>();
      final closed = Completer<void>();
      listener.listen((socket) {
        peers.add(socket);
        if (!accepted.isCompleted) accepted.complete();
        socket.listen(
          (_) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      final transport = DartSshTransport(SshHostKeyTrust(InMemoryHostKeyStore()));
      try {
        await expectLater(
          transport.openDedicatedClient(
            SshCredentials(
              host: InternetAddress.loopbackIPv4.address,
              port: listener.port,
              username: 'repository-fixture',
              privateKeyPem: bastion ? null : 'deliberately malformed test key',
              proxyType: bastion ? 'ssh' : 'none',
              proxyHost: InternetAddress.loopbackIPv4.address,
              proxyPort: listener.port,
              proxyUser: 'repository-fixture',
              proxyKeyPem: bastion ? 'deliberately malformed test key' : null,
            ),
          ),
          throwsA(isA<InvalidPrivateKeyException>()),
        );
        await accepted.future.timeout(const Duration(seconds: 2));
        final released = await closed.future
            .then((_) => true)
            .timeout(const Duration(seconds: 2), onTimeout: () => false);
        expect(released, isTrue, reason: 'setup failure must release its owned socket');
      } finally {
        transport.shutdown();
        for (final peer in peers) {
          peer.destroy();
        }
        await listener.close();
      }
    });
  }
}
