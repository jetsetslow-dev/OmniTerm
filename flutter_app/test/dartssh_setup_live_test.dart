import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

/// Real OpenSSH protocol tests using only scripts/test-hosts.sh's loopback fixture. The relay
/// changes packet delivery on connections this test owns; it never changes the fixture daemon.
void main() {
  final enabled = Platform.environment['OMNITERM_SETUP_FIXTURE'] == 'yes';
  final user = Platform.environment['OMNITERM_TEST_USER'];
  final password = Platform.environment['OMNITERM_TEST_PASSWORD'];

  for (final stage in ['approval', 'authentication', 'forwarding']) {
    test(
      'OpenSSH setup: $stage preserves approval time and bounds network waits',
      () async {
        expect(user, isNotEmpty);
        expect(password, isNotEmpty);
        final relay = await _FixtureRelay.open(stage == 'forwarding' ? 2203 : 2205);
        final trust = SshHostKeyTrust(InMemoryHostKeyStore());
        final owner = Object();
        Timer? approvalTimer;
        var prompted = false;
        trust.registerApprovalHandler(owner, (request) {
          expect(request.host, InternetAddress.loopbackIPv4.address);
          prompted = true;
          if (stage == 'approval') {
            // Exceeds the production 15-second network deadline while staying well inside the
            // existing 120-second approval window. No trust bypass or cached pin is involved.
            approvalTimer = Timer(const Duration(seconds: 16), () {
              if (!request.completer.isCompleted) request.completer.complete(true);
            });
          } else {
            if (stage == 'authentication') relay.dropServerOutput = true;
            request.completer.complete(true);
          }
        });
        final transport = DartSshTransport(trust);
        TerminalSession? shell;
        try {
          final credentials = SshCredentials(
            host: stage == 'forwarding'
                ? 'omniterm-test-internal-a'
                : InternetAddress.loopbackIPv4.address,
            port: stage == 'forwarding' ? 2222 : relay.port,
            username: user!,
            password: password,
            proxyType: stage == 'forwarding' ? 'ssh' : 'none',
            proxyHost: InternetAddress.loopbackIPv4.address,
            proxyPort: relay.port,
            proxyUser: user,
            proxyPassword: password ?? '',
          );
          final phases = <String>[];
          final connection = transport.openShell(
            credentials,
            80,
            24,
            onPhaseChange: (phase) {
              phases.add(phase);
              if (stage == 'forwarding' && phase == 'Opening bastion tunnel…') {
                relay.dropServerOutput = true;
              }
            },
          );
          if (stage == 'approval') {
            shell = await connection.timeout(const Duration(seconds: 35));
            expect(shell.closed.value, isFalse);
            expect(phases, contains('Opening channel…'));
          } else {
            final expectedPhase = stage == 'forwarding'
                ? 'Bastion SSH forwarding'
                : 'Target SSH authentication';
            await expectLater(
              connection.timeout(const Duration(seconds: 20)),
              throwsA(
                isA<SshConnectException>().having(
                  (error) => '$error',
                  'failed stage',
                  contains('$expectedPhase timed out'),
                ),
              ),
            );
            await relay.clientClosed.future.timeout(const Duration(seconds: 2));
          }
          expect(prompted, isTrue, reason: 'The test must reach real host-key verification');
        } finally {
          approvalTimer?.cancel();
          shell?.close();
          transport.shutdown();
          trust.clearApprovalHandler(owner);
          await relay.close();
        }
      },
      skip: enabled ? false : 'enable OMNITERM_SETUP_FIXTURE with repository SSH fixtures',
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}

class _FixtureRelay {
  _FixtureRelay(this.listener);

  final ServerSocket listener;
  final sockets = <Socket>[];
  final clientClosed = Completer<void>();
  bool dropServerOutput = false;
  bool _closed = false;

  int get port => listener.port;

  static Future<_FixtureRelay> open(int fixturePort) async {
    final relay = _FixtureRelay(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    relay.listener.listen((client) async {
      relay.sockets.add(client);
      final server = await Socket.connect(InternetAddress.loopbackIPv4, fixturePort);
      relay.sockets.add(server);
      if (relay._closed) {
        server.destroy();
        client.destroy();
        return;
      }
      client.listen(
        server.add,
        onError: (Object _) => server.destroy(),
        onDone: () {
          if (!relay.clientClosed.isCompleted) relay.clientClosed.complete();
          server.destroy();
        },
      );
      server.listen(
        (bytes) {
          if (!relay.dropServerOutput) client.add(bytes);
        },
        onError: (Object _) => client.destroy(),
        onDone: client.destroy,
      );
    });
    return relay;
  }

  Future<void> close() async {
    _closed = true;
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.close();
  }
}
