import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/domain/server_credentials.dart';

/// One resolver decides which secret a host connects with, so its refusals matter as much as its
/// successes: a missing key must never quietly become a password attempt.
void main() {
  Server server({
    String authType = 'password',
    String? authPassword = 'pw',
    String? authKeyAlias,
    int? authProfileId,
    String proxyType = 'none',
    String? proxyKeyAlias,
  }) =>
      Server(
        id: 1,
        name: 'nas',
        host: '10.0.0.2',
        port: 2222,
        username: 'root',
        serverColor: 'Default',
        authType: authType,
        authPassword: authPassword,
        authKeyAlias: authKeyAlias,
        authProfileId: authProfileId,
        sudoPassword: '',
        notes: '',
        keepAlive: 45,
        sshCompression: true,
        persistentSession: false,
        proxyCommand: '',
        proxyType: proxyType,
        proxyHost: proxyType == 'none' ? '' : 'bastion',
        proxyPort: proxyType == 'none' ? 0 : 2200,
        proxyUser: 'jump',
        proxyPassword: 'jump-pw',
        proxyKeyAlias: proxyKeyAlias,
        agentForwarding: true,
        healthScore: 100,
        lastLatency: 0,
        status: 'offline',
        authStatus: 'unknown',
      );

  SshKey key(String alias, String pem) => SshKey(
        id: alias.hashCode,
        alias: alias,
        keyType: 'Ed25519',
        privateKey: pem,
        publicKey: 'ssh-ed25519 AAAA',
        fingerprint: 'SHA256:x',
      );

  test('a password host carries its password and no key', () {
    final creds = resolveCredentials(server());
    expect(creds.host, '10.0.0.2');
    expect(creds.port, 2222);
    expect(creds.username, 'root');
    expect(creds.password, 'pw');
    expect(creds.privateKeyPem, isNull);
  });

  test('non-secret connection settings are carried through', () {
    final creds = resolveCredentials(server());
    expect(creds.keepAliveSeconds, 45);
    expect(creds.compression, isTrue);
    expect(creds.agentForwarding, isTrue);
  });

  test('an empty password becomes null rather than an empty attempt', () {
    expect(resolveCredentials(server(authPassword: '')).password, isNull);
  });

  group('key authentication', () {
    test('resolves the alias to the saved key material', () {
      final creds = resolveCredentials(
        server(authType: 'key', authKeyAlias: 'laptop'),
        keys: [key('laptop', 'PEM-LAPTOP')],
      );
      expect(creds.privateKeyPem, 'PEM-LAPTOP');
    });

    test('a key host never also offers its stored password', () {
      // Otherwise a server that rejects the key could harvest the password instead.
      final creds = resolveCredentials(
        server(authType: 'key', authKeyAlias: 'laptop', authPassword: 'pw'),
        keys: [key('laptop', 'PEM')],
      );
      expect(creds.password, isNull);
    });

    test('a missing key is an error, not a fallback to the password', () {
      expect(
        () => resolveCredentials(
          server(authType: 'key', authKeyAlias: 'gone', authPassword: 'pw'),
          keys: [key('laptop', 'PEM')],
        ),
        throwsA(isA<CredentialResolutionException>()),
      );
    });

    test('a key host with no alias selected is an error', () {
      expect(
        () => resolveCredentials(server(authType: 'key')),
        throwsA(isA<CredentialResolutionException>()),
      );
    });
  });

  group('credential profiles', () {
    CredentialProfile profile({
      int id = 5,
      String authType = 'password',
      String? password = 'profile-pw',
      String? keyAlias,
    }) =>
        CredentialProfile(
          id: id,
          profileName: 'shared',
          username: 'deploy',
          authType: authType,
          password: password,
          keyAlias: keyAlias,
          groupName: 'General',
        );

    test('the profile supplies the username and password', () {
      final creds = resolveCredentials(
        server(authType: 'profile', authProfileId: 5),
        profiles: [profile()],
      );
      expect(creds.username, 'deploy', reason: 'the profile is the identity, not the host row');
      expect(creds.password, 'profile-pw');
    });

    test('a key-typed profile resolves through the same key rules', () {
      final creds = resolveCredentials(
        server(authType: 'profile', authProfileId: 5),
        profiles: [profile(authType: 'key', password: 'unused', keyAlias: 'laptop')],
        keys: [key('laptop', 'PEM')],
      );
      expect(creds.privateKeyPem, 'PEM');
      expect(creds.password, isNull, reason: 'a key profile must not fall back to its password');
    });

    test('a deleted profile is an error rather than a connection as the host user', () {
      expect(
        () => resolveCredentials(server(authType: 'profile', authProfileId: 5)),
        throwsA(isA<CredentialResolutionException>()),
      );
    });

    test('a profile auth type with no profile selected is an error', () {
      expect(
        () => resolveCredentials(server(authType: 'profile')),
        throwsA(isA<CredentialResolutionException>()),
      );
    });
  });

  group('jump host', () {
    test('resolves the jump key separately from the target key', () {
      final creds = resolveCredentials(
        server(
          authType: 'key',
          authKeyAlias: 'target',
          proxyType: 'ssh',
          proxyKeyAlias: 'bastion',
        ),
        keys: [key('target', 'PEM-TARGET'), key('bastion', 'PEM-BASTION')],
      );
      expect(creds.privateKeyPem, 'PEM-TARGET');
      expect(creds.proxyKeyPem, 'PEM-BASTION');
      expect(creds.proxyHost, 'bastion');
      expect(creds.proxyPort, 2200);
    });

    test('a missing jump key is an error', () {
      expect(
        () => resolveCredentials(
          server(proxyType: 'ssh', proxyKeyAlias: 'gone'),
        ),
        throwsA(isA<CredentialResolutionException>()),
      );
    });

    test('a non-ssh proxy ignores any stale key alias', () {
      final creds = resolveCredentials(server(proxyType: 'http', proxyKeyAlias: 'gone'));
      expect(creds.proxyKeyPem, isNull, reason: 'a key means nothing to an HTTP proxy');
    });
  });
}
