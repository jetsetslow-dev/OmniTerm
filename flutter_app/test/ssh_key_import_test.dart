import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/ssh_key_import.dart';

import 'support/ed25519_fixture.dart';

/// Importing a key is where unusable material must be rejected. A key stored here and rejected at
/// connect time produces a cryptic error while the user is trying to do something else.
void main() {
  // Generated rather than committed: see test/support/ed25519_fixture.dart.
  late Ed25519Fixture keys;
  late String ed25519Private;
  late String ed25519Public;

  setUpAll(() async {
    keys = await sharedEd25519Fixture();
    ed25519Private = keys.privateKey;
    ed25519Public = keys.publicKey;
  });

  group('rejections', () {
    test('an empty alias is refused', () {
      expect(
        () => prepareKeyImport(alias: '  ', privateKey: ed25519Private),
        throwsA(isA<KeyImportException>()),
      );
    });

    test('a duplicate alias is refused', () {
      // An alias is how a host names its key; two would make it ambiguous which one is used.
      expect(
        () => prepareKeyImport(
          alias: 'laptop',
          privateKey: ed25519Private,
          existingAliases: {'laptop'},
        ),
        throwsA(
          isA<KeyImportException>().having((e) => e.message, 'message', contains('already exists')),
        ),
      );
    });

    test('empty key material is refused', () {
      expect(
        () => prepareKeyImport(alias: 'k', privateKey: '   '),
        throwsA(isA<KeyImportException>()),
      );
    });

    test('pasting a public key into the private field says exactly that', () {
      // The two files sit side by side and differ only by a .pub suffix, so this is the single most
      // likely mistake — and "invalid key" would not help at all.
      expect(
        () => prepareKeyImport(alias: 'k', privateKey: ed25519Public),
        throwsA(
          isA<KeyImportException>().having((e) => e.message, 'message', contains('public key')),
        ),
      );
    });

    test('arbitrary text is refused with a usable hint', () {
      expect(
        () => prepareKeyImport(alias: 'k', privateKey: 'hello world'),
        throwsA(
          isA<KeyImportException>().having((e) => e.message, 'message', contains('PRIVATE KEY')),
        ),
      );
    });
  });

  group('a valid import', () {
    test('is accepted and trimmed', () {
      final key = prepareKeyImport(
        alias: '  laptop  ',
        privateKey: '\n$ed25519Private\n',
        publicKey: ed25519Public,
      );
      expect(key.alias, 'laptop');
      expect(key.privateKey, ed25519Private);
    });

    test('detects the type from the public line', () {
      final key = prepareKeyImport(
        alias: 'laptop',
        privateKey: ed25519Private,
        publicKey: ed25519Public,
      );
      expect(key.keyType, 'ED25519');
    });

    test('an explicit type wins over detection', () {
      final key = prepareKeyImport(
        alias: 'laptop',
        privateKey: ed25519Private,
        publicKey: ed25519Public,
        keyType: 'YubiKey',
      );
      expect(key.keyType, 'YubiKey');
    });

    test('with no public key it reports the container rather than guessing', () {
      // A modern OpenSSH container does not reveal its inner algorithm without parsing.
      final key = prepareKeyImport(alias: 'laptop', privateKey: ed25519Private);
      expect(key.keyType, 'OpenSSH');
      expect(key.publicKey, isEmpty);
    });

    test('a public key in the wrong shape is ignored, not stored', () {
      final key = prepareKeyImport(
        alias: 'laptop',
        privateKey: ed25519Private,
        publicKey: 'not a public key',
      );
      expect(key.publicKey, isEmpty);
    });
  });

  group('fingerprints', () {
    test('a public line fingerprints the way ssh-keygen does', () {
      // Hashing the decoded blob — not the text — is what makes this comparable to the fingerprint
      // the server prints, which is the entire reason to show one.
      final blob = base64.decode(ed25519Public.split(RegExp(r'\s+'))[1]);
      final expected =
          'SHA256:${base64.encode(sha256.convert(blob).bytes).replaceAll(RegExp(r'=+$'), '')}';

      expect(sshPublicKeyFingerprint(ed25519Public), expected);
      expect(
        prepareKeyImport(
          alias: 'k',
          privateKey: ed25519Private,
          publicKey: ed25519Public,
        ).fingerprint,
        expected,
      );
    });

    test('the trailing base64 padding is stripped, as OpenSSH does', () {
      expect(sshPublicKeyFingerprint(ed25519Public), isNot(endsWith('=')));
    });

    test('a comment does not change the fingerprint', () {
      // The same key with its trailing comment stripped, derived from the generated line rather
      // than pasted: a hardcoded copy would only ever test the one key it was written against.
      final withoutComment = ed25519Public.split(' ').take(2).join(' ');
      expect(
        sshPublicKeyFingerprint(ed25519Public),
        sshPublicKeyFingerprint(withoutComment),
        reason: 'the comment is a label, not part of the key',
      );
    });

    test('without a public key it still produces a stable identifier', () {
      // Not comparable with the server's, but it makes duplicates visible in the list.
      final a = prepareKeyImport(alias: 'a', privateKey: ed25519Private).fingerprint;
      final b = prepareKeyImport(alias: 'b', privateKey: ed25519Private).fingerprint;
      expect(a, startsWith('SHA256:'));
      expect(a, b);
    });

    test('malformed base64 falls back instead of throwing', () {
      // A wrong fingerprint is cosmetic; refusing the import over it would not be.
      expect(() => sshPublicKeyFingerprint('ssh-rsa !!!not-base64!!!'), returnsNormally);
      expect(sshPublicKeyFingerprint('ssh-rsa !!!not-base64!!!'), startsWith('SHA256:'));
    });
  });

  group('detectKeyType', () {
    test('reads the algorithm from a public line', () {
      expect(detectKeyType('', 'ssh-ed25519 AAAA'), 'ED25519');
      expect(detectKeyType('', 'ssh-rsa AAAA'), 'RSA');
      expect(detectKeyType('', 'ecdsa-sha2-nistp256 AAAA'), 'ECDSA');
      expect(detectKeyType('', 'ssh-dss AAAA'), 'DSA');
    });

    test('falls back to legacy PEM headers', () {
      expect(detectKeyType(pemBegin('RSA'), ''), 'RSA');
      expect(detectKeyType(pemBegin('EC'), ''), 'ECDSA');
      expect(detectKeyType(pemBegin('DSA'), ''), 'DSA');
    });

    test('an unrecognised key is labelled honestly', () {
      expect(detectKeyType('something', ''), 'SSH Key');
    });
  });

  test('isPublicKeyLine accepts the OpenSSH prefixes only', () {
    expect(isPublicKeyLine('ssh-ed25519 AAAA'), isTrue);
    expect(isPublicKeyLine('  ecdsa-sha2-nistp256 AAAA'), isTrue);
    expect(isPublicKeyLine(pemBegin('OPENSSH')), isFalse);
    expect(isPublicKeyLine(''), isFalse);
  });
}
