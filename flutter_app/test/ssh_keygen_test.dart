import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/ssh_private_key.dart';
import 'package:omniterm/domain/ssh_key_import.dart';
import 'package:omniterm/domain/ssh_keygen.dart';

import 'support/ed25519_fixture.dart';

/// Guards on-device SSH key generation, ported from `generateSshKey` in `ui/AppViewModel.kt`.
///
/// The encodings are the whole risk here: a key that OmniTerm stores happily but OpenSSH cannot read
/// fails on the server, long after generation, with no useful diagnostic. So the assertions go
/// through a real parser rather than checking that the text merely looks PEM-shaped.
///
/// Generation uses a small modulus for speed. Size is a parameter of the algorithm, not of the
/// encoding under test, so a 1024-bit key exercises exactly the same code paths as the 4096-bit key
/// production generates.
void main() {
  group('generateSshKeyPair', () {
    test('rejects a blank alias', () {
      expect(
        () => generateSshKeyPair(alias: '  ', bits: 512),
        throwsA(
          isA<KeyGenerationException>().having(
            (e) => e.message,
            'message',
            'Key alias is required.',
          ),
        ),
      );
    });

    test('rejects an alias that is already stored', () {
      expect(
        () => generateSshKeyPair(alias: 'laptop', existingAliases: {'laptop'}, bits: 512),
        throwsA(
          isA<KeyGenerationException>().having(
            (e) => e.message,
            'message',
            'Key alias already exists.',
          ),
        ),
      );
    });

    test('refuses an unsupported type and names the workaround', () {
      // Kotlin points the user at import rather than silently handing back an RSA key under an
      // Ed25519 label; the message is what makes that recoverable.
      expect(
        () => generateSshKeyPair(alias: 'laptop', keyType: 'ED25519', bits: 512),
        throwsA(
          isA<KeyGenerationException>().having(
            (e) => e.message,
            'message',
            'ED25519 key generation is not supported by the bundled SSH library. '
                'Import an existing key instead.',
          ),
        ),
      );
    });

    test('produces a private key the SSH client can actually parse', () {
      final generated = generateSshKeyPair(alias: 'laptop', bits: 1024);

      expect(generated.keyType, 'RSA');
      expect(generated.privateKey, startsWith(pemBegin('RSA')));
      expect(generated.privateKey, endsWith('${pemEnd('RSA')}\n'));
      // The import path's own validator must accept it, or a generated key could not be re-imported.
      expect(privateKeyParseError(generated.privateKey), isNull);
      expect(parsePrivateKey(generated.privateKey), isNotEmpty);
    });

    test('produces an authorized_keys line tagged with the alias', () {
      final generated = generateSshKeyPair(alias: 'work laptop', bits: 1024);

      final parts = generated.publicKey.split(' ');
      expect(parts.first, 'ssh-rsa');
      expect(parts.last, 'work laptop'.split(' ').last);
      expect(isPublicKeyLine(generated.publicKey), isTrue);
      expect(generated.fingerprint, startsWith('SHA256:'));
      expect(generated.fingerprint, sshPublicKeyFingerprint(generated.publicKey));
    });

    test('two runs never return the same key', () {
      final first = generateSshKeyPair(alias: 'a', bits: 512);
      final second = generateSshKeyPair(alias: 'b', bits: 512);
      expect(first.privateKey, isNot(second.privateKey));
      expect(first.fingerprint, isNot(second.fingerprint));
    });

    test('the install command carries the public line and fixes the permissions', () {
      final generated = generateSshKeyPair(alias: 'laptop', bits: 512);
      final command = authorizedKeysInstallCommand(generated.publicKey);

      expect(command, contains(generated.publicKey));
      expect(command, contains('chmod 700 ~/.ssh'));
      expect(command, contains('chmod 600 ~/.ssh/authorized_keys'));
      // Appends: overwriting authorized_keys would lock the user out of their own server.
      expect(command, contains('>> ~/.ssh/authorized_keys'));
    });
  });

  group('OpenSSH agreement', () {
    // The only assertion that proves the encoding is right rather than merely self-consistent:
    // OpenSSH re-derives the public key from our private key and must reach the same line. Skipped
    // where ssh-keygen is absent so the suite stays host independent.
    final sshKeygen = _whichSshKeygen();

    test(
      'ssh-keygen derives the same public key and fingerprint from our PEM',
      () {
        final generated = generateSshKeyPair(alias: 'laptop', bits: 1024);
        final dir = Directory.systemTemp.createTempSync('omniterm-keygen-test');
        addTearDown(() => dir.deleteSync(recursive: true));

        final pem = File('${dir.path}/id_rsa')..writeAsStringSync(generated.privateKey);
        // ssh-keygen refuses to read a world-readable private key.
        Process.runSync('chmod', ['600', pem.path]);

        final derived = Process.runSync(sshKeygen!, ['-y', '-f', pem.path]);
        expect(derived.exitCode, 0, reason: 'ssh-keygen could not read our PEM: ${derived.stderr}');

        final derivedLine = (derived.stdout as String).trim();
        // ssh-keygen -y prints no comment, so compare the algorithm and blob only.
        expect(
          derivedLine.split(' ').take(2).join(' '),
          generated.publicKey.split(' ').take(2).join(' '),
        );

        final printed = Process.runSync(sshKeygen, ['-lf', pem.path]);
        expect(printed.exitCode, 0);
        expect((printed.stdout as String), contains(generated.fingerprint));
      },
      skip: sshKeygen == null ? 'ssh-keygen is not installed on this host' : null,
    );
  });
}

String? _whichSshKeygen() {
  for (final candidate in const ['/usr/bin/ssh-keygen', '/bin/ssh-keygen']) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
