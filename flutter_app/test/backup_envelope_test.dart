import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/backup/backup_envelope.dart';

/// A backup file is untrusted input: it arrives from a cloud drive, a chat message, or an attacker.
/// These tests are mostly about what a *hostile* file cannot make the app do.
void main() {
  const passphrase = 'correct horse battery staple';
  const payload = '{"servers":[{"name":"nas","host":"10.0.0.2"}]}';

  group('round trip', () {
    test('what goes in comes out', () async {
      final envelope = await encryptBackup(payload, passphrase);
      expect(await decryptBackup(envelope, passphrase), payload);
    });

    test('the envelope declares the format it used', () async {
      final envelope = jsonDecode(await encryptBackup(payload, passphrase)) as Map;
      expect(envelope['v'], 2);
      expect(envelope['compression'], 'gzip');
      expect(envelope['kdf'], 'PBKDF2WithHmacSHA256');
      expect(envelope['iterations'], BackupLimits.kdfIterations);
    });

    test('the plaintext never appears in the file', () async {
      // The obvious failure to check for: encryption that silently did not happen.
      final envelope = await encryptBackup(payload, passphrase);
      expect(envelope, isNot(contains('nas')));
      expect(envelope, isNot(contains('10.0.0.2')));
      expect(envelope, isNot(contains(passphrase)));
    });

    test('two backups of the same data differ', () async {
      // A fresh salt and nonce each time; identical ciphertext would leak that nothing changed
      // between two exports.
      final first = await encryptBackup(payload, passphrase);
      final second = await encryptBackup(payload, passphrase);
      expect(first, isNot(second));
    });

    test('an empty passphrase is refused rather than producing a useless file', () async {
      expect(() => encryptBackup(payload, ''), throwsA(isA<BackupException>()));
    });
  });

  group('a wrong passphrase', () {
    test('is reported as a wrong passphrase, not as a damaged file', () async {
      // This is why the cipher is authenticated. Without the tag, a bad key decrypts to garbage
      // that then fails to parse, and the user is told their backup is corrupt.
      final envelope = await encryptBackup(payload, passphrase);
      await expectLater(
        decryptBackup(envelope, 'wrong passphrase'),
        throwsA(
          isA<BackupException>()
              .having((e) => e.message, 'message', contains('passphrase does not match')),
        ),
      );
    });

    test('a tampered ciphertext is caught by the tag', () async {
      final envelope = jsonDecode(await encryptBackup(payload, passphrase)) as Map<String, dynamic>;
      final data = base64.decode(envelope['data'] as String);
      // Flip one bit in the middle of the ciphertext.
      data[data.length ~/ 2] ^= 0x01;
      envelope['data'] = base64.encode(data);

      await expectLater(
        decryptBackup(jsonEncode(envelope), passphrase),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('hostile envelopes', () {
    Future<Map<String, dynamic>> validEnvelope() async =>
        jsonDecode(await encryptBackup(payload, passphrase)) as Map<String, dynamic>;

    test('a weak KDF work factor is refused', () async {
      // A crafted file claiming one iteration would make guessing the passphrase offline cheap.
      final envelope = await validEnvelope();
      envelope['iterations'] = 1;
      await expectLater(
        decryptBackup(jsonEncode(envelope), passphrase),
        throwsA(
          isA<BackupException>()
              .having((e) => e.message, 'message', contains('unsafe key-derivation')),
        ),
      );
    });

    test('an absurd KDF work factor is refused too', () async {
      // One claiming a billion iterations would wedge the device before failing.
      final envelope = await validEnvelope();
      envelope['iterations'] = 1000000000;
      await expectLater(
        decryptBackup(jsonEncode(envelope), passphrase),
        throwsA(isA<BackupException>()),
      );
    });

    test('a wrong salt or IV length is refused', () async {
      for (final field in ['salt', 'iv']) {
        final envelope = await validEnvelope();
        envelope[field] = base64.encode(List.filled(4, 0));
        await expectLater(
          decryptBackup(jsonEncode(envelope), passphrase),
          throwsA(isA<BackupException>()),
          reason: field,
        );
      }
    });

    test('a ciphertext too short to carry a tag is refused', () async {
      final envelope = await validEnvelope();
      envelope['data'] = base64.encode(List.filled(8, 0));
      await expectLater(
        decryptBackup(jsonEncode(envelope), passphrase),
        throwsA(isA<BackupException>()),
      );
    });

    test('an unknown compression is refused rather than guessed at', () async {
      final envelope = await validEnvelope();
      envelope['compression'] = 'brotli';
      await expectLater(
        decryptBackup(jsonEncode(envelope), passphrase),
        throwsA(
          isA<BackupException>()
              .having((e) => e.message, 'message', contains('compression')),
        ),
      );
    });

    test('a missing field is reported, not dereferenced', () async {
      for (final field in ['salt', 'iv', 'data']) {
        final envelope = await validEnvelope()..remove(field);
        await expectLater(
          decryptBackup(jsonEncode(envelope), passphrase),
          throwsA(isA<BackupException>()),
          reason: field,
        );
      }
    });

    test('text that is not JSON at all says so plainly', () async {
      await expectLater(
        decryptBackup('this is not a backup', passphrase),
        throwsA(
          isA<BackupException>()
              .having((e) => e.message, 'message', contains('does not look like')),
        ),
      );
    });

    test('base64 that is not base64 is refused', () async {
      final envelope = await validEnvelope();
      envelope['salt'] = '!!! not base64 !!!';
      await expectLater(
        decryptBackup(jsonEncode(envelope), passphrase),
        throwsA(isA<BackupException>()),
      );
    });

    test('deeply nested JSON is refused before it is parsed', () async {
      // Deep nesting is the standard way to blow a recursive-descent parser's stack.
      final nested = '${'[' * 200}${']' * 200}';
      await expectLater(
        decryptBackup(nested, passphrase),
        throwsA(
          isA<BackupException>()
              .having((e) => e.message, 'message', contains('nested too deeply')),
        ),
      );
    });

    test('nesting inside a string literal is not counted', () async {
      // Otherwise a legitimate backup containing a command like `awk '{{{...}}}'` would be refused.
      final envelope = await encryptBackup('{"note":"${'[' * 100}"}', passphrase);
      expect(await decryptBackup(envelope, passphrase), contains('['));
    });

    test('an oversized file is refused before any work is done', () async {
      final huge = 'a' * (BackupLimits.maxInputChars + 1);
      await expectLater(
        decryptBackup(huge, passphrase),
        throwsA(
          isA<BackupException>().having((e) => e.message, 'message', contains('too large')),
        ),
      );
    });
  });

  group('gunzipBounded', () {
    test('passes ordinary data through', () {
      final data = utf8.encode('hello world' * 100);
      final compressed = Uint8List.fromList(gzip.encode(data));
      expect(gunzipBounded(compressed), data);
    });

    test('refuses a zip bomb by expansion ratio', () {
      // A few kilobytes of zeros expands enormously; the ratio catches it long before the absolute
      // cap would.
      final bomb = Uint8List.fromList(gzip.encode(List.filled(50 * 1024 * 1024, 0)));
      expect(
        () => gunzipBounded(bomb),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            anyOf(contains('safe restore limit'), contains('too large')),
          ),
        ),
      );
    });

    test('refuses compressed input above the cap', () {
      expect(
        () => gunzipBounded(Uint8List(20), maxCompressedBytes: 10),
        throwsA(isA<BackupException>()),
      );
    });

    test('damaged gzip is reported, not thrown raw', () {
      expect(
        () => gunzipBounded(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('damaged'))),
      );
    });
  });

  group('validateCryptoParameters', () {
    test('accepts the parameters this app writes', () {
      expect(
        () => validateCryptoParameters(
          iterations: BackupLimits.kdfIterations,
          saltSize: BackupLimits.saltBytes,
          ivSize: BackupLimits.ivBytes,
          ciphertextSize: 1024,
        ),
        returnsNormally,
      );
    });

    test('accepts the floor and ceiling exactly', () {
      for (final iterations in [BackupLimits.minKdfIterations, BackupLimits.maxKdfIterations]) {
        expect(
          () => validateCryptoParameters(
            iterations: iterations,
            saltSize: 16,
            ivSize: 12,
            ciphertextSize: 1024,
          ),
          returnsNormally,
          reason: '$iterations',
        );
      }
    });
  });
}
