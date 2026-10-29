import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

/// Measures where connect time actually goes, against the repository's own fixtures.
///
/// The handover recorded a *hypothesis* — "Flutter does not pool bastion clients, so sequential
/// probes can each reauthenticate" — and was explicit that it must be measured rather than claimed.
/// This reports numbers instead of asserting thresholds: wall-clock budgets would be a flaky gate
/// and, worse, would read as a promise about user hosts. These are loopback Docker containers on
/// one machine; the *shape* transfers, the milliseconds do not.
///
/// The only assertions are structural, about reuse rather than speed, because that is the part of
/// the hypothesis that is a fact about the code rather than about a network.
void main() {
  final enabled = Platform.environment['OMNITERM_SETUP_FIXTURE'] == 'yes';
  final user = Platform.environment['OMNITERM_TEST_USER'];
  final password = Platform.environment['OMNITERM_TEST_PASSWORD'];

  SshCredentials direct() => SshCredentials(
    host: InternetAddress.loopbackIPv4.address,
    port: 2201,
    username: user!,
    password: password,
  );

  SshCredentials throughBastion() => SshCredentials(
    host: 'omniterm-test-internal-a',
    port: 2222,
    username: user!,
    password: password,
    proxyType: 'ssh',
    proxyHost: InternetAddress.loopbackIPv4.address,
    proxyPort: 2203,
    proxyUser: user,
    proxyPassword: password ?? '',
  );

  Future<int> millis(Future<void> Function() body) async {
    final started = DateTime.now();
    await body();
    return DateTime.now().difference(started).inMilliseconds;
  }

  test(
    'where connect time goes, measured on repository fixtures',
    () async {
      expect(user, isNotEmpty);
      final trust = SshHostKeyTrust(InMemoryHostKeyStore());
      final owner = Object();
      trust.registerApprovalHandler(owner, (request) => request.completer.complete(true));
      final transport = DartSshTransport(trust);
      final report = StringBuffer(
        '\nfixture connect measurements (loopback Docker, one machine)\n',
      );
      try {
        final firstDirect = await millis(() => transport.exec(direct(), 'true'));
        report.writeln('  direct  first exec (connect + auth + channel) : ${firstDirect}ms');

        // The same credentials again. If the pool works, this is a channel on a live connection.
        final secondDirect = await millis(() => transport.exec(direct(), 'true'));
        report.writeln('  direct  second exec (pooled connection)       : ${secondDirect}ms');

        final firstJump = await millis(() => transport.exec(throughBastion(), 'true'));
        report.writeln('  bastion first exec (jump auth + target auth)  : ${firstJump}ms');

        final secondJump = await millis(() => transport.exec(throughBastion(), 'true'));
        report.writeln('  bastion second exec (NOT pooled, by design)   : ${secondJump}ms');

        report.writeln(
          '  bastion first-connect overhead vs direct      : '
          '${firstJump - firstDirect}ms',
        );
        // ignore: avoid_print
        print(report.toString());

        // Structural, not a budget. Halving is far outside the noise a loaded machine produces,
        // while a wall-clock threshold would be both flaky and a promise about user hosts.
        expect(
          secondDirect * 2,
          lessThan(firstDirect),
          reason: 'a second probe on the same credentials must reuse the pooled connection',
        );

        // No equivalent assertion for the bastion, deliberately. `_acquire` leases jump
        // connections `unpooled`, so every probe through a bastion repeats the whole handshake —
        // and Compose does the same ("Jump-host sessions are not pooled", `JschSftp.kt:29`). This
        // is parity and a shared limitation, not a Flutter regression, so the measurement above
        // reports it rather than asserting it away. An earlier version of this test asserted
        // `secondJump < firstJump` and passed on 269ms versus 279ms — noise, and it would have
        // passed whether or not any reuse happened, which is exactly the kind of guard that
        // proves nothing.
        expect(
          secondJump,
          greaterThan(0),
          reason: 'a second bastion probe must still succeed, however it is dialled',
        );
      } finally {
        transport.shutdown();
        trust.clearApprovalHandler(owner);
      }
    },
    skip: enabled ? null : 'enable OMNITERM_SETUP_FIXTURE with repository SSH fixtures',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
