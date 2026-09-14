import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

void main() {
  final host = Platform.environment['OMNITERM_COMPRESSION_HOST'];
  final port = int.tryParse(Platform.environment['OMNITERM_COMPRESSION_PORT'] ?? '');
  final username = Platform.environment['OMNITERM_COMPRESSION_USER'];
  final keyPath = Platform.environment['OMNITERM_COMPRESSION_KEY'];
  final configured = host != null && port != null && username != null && keyPath != null;

  test(
    'production transport enables delayed zlib for compression credentials',
    () async {
      final trust = SshHostKeyTrust(InMemoryHostKeyStore());
      final approvalOwner = Object();
      trust.registerApprovalHandler(approvalOwner, (request) => request.completer.complete(true));
      final debug = <String>[];
      final transport = DartSshTransport(
        trust,
        printDebug: (line) {
          if (line != null) debug.add(line);
        },
      );
      try {
        final output = await transport.exec(
          SshCredentials(
            host: host!,
            port: port!,
            username: username!,
            privateKeyPem: File(keyPath!).readAsStringSync(),
            compression: true,
          ),
          'yes omniterm-compression | head -n 1000',
        );

        expect(output.split('\n').where((line) => line == 'omniterm-compression'), hasLength(1000));
        expect(debug, contains('SSHTransport._clientCompression: zlib@openssh.com'));
        expect(debug, contains('SSHTransport._serverCompression: zlib@openssh.com'));
      } finally {
        transport.shutdown();
        trust.clearApprovalHandler(approvalOwner);
      }
    },
    skip: configured ? false : 'set OMNITERM_COMPRESSION_* for a disposable OpenSSH fixture',
  );
}
