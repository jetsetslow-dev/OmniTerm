import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_private_key.dart';

import 'support/ed25519_fixture.dart';

void main() {
  SshCredentials creds({required bool agentForwarding}) => SshCredentials(
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    agentForwarding: agentForwarding,
  );

  late List<SSHKeyPair> identities;

  setUpAll(() async {
    // Generated, never committed: a secret-shaped literal in the tree is indistinguishable from a
    // real leak to a scanner, and this repository's secret gate scans all history.
    final fixture = await sharedEd25519Fixture();
    identities = parsePrivateKey(fixture.privateKey);
    expect(
      identities,
      isNotEmpty,
      reason: 'the fixture key must parse, or the tests prove nothing',
    );
  });

  test('a host with agent forwarding on is served an agent', () {
    // The defect: `agentForwarding` travelled from the host form through `SshCredentials` and was
    // never read, so the switch stored a value and changed nothing. Kotlin acts on it at
    // `JschSshTransport.kt:351`.
    expect(agentHandlerFor(creds(agentForwarding: true), identities), isA<SSHKeyPairAgent>());
  });

  test('a host with it off is served none', () {
    expect(agentHandlerFor(creds(agentForwarding: false), identities), isNull);
  });

  test('a password host is served none even with the switch on', () {
    // There is nothing to forward without a key. An empty agent would ask the server for a
    // forwarding channel that could never sign anything.
    expect(agentHandlerFor(creds(agentForwarding: true), const []), isNull);
  });
}
