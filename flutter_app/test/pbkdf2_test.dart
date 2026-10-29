import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/pbkdf2.dart';

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('pbkdf2HmacSha256', () {
    test('matches the RFC 7914 test vectors', () {
      expect(
        _hex(pbkdf2HmacSha256(utf8.encode('passwd'), utf8.encode('salt'), 1, 64)),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
      expect(
        _hex(pbkdf2HmacSha256(utf8.encode('Password'), utf8.encode('NaCl'), 80000, 64)),
        '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56'
        'a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d',
      );
    });

    // The key and backup formats are shared with Kotlin, and package:cryptography is what wrote
    // every existing PIN hash and backup. Key lengths either side of the 64-byte block (a longer
    // key is hashed first), salts either side of where the padding spills into a second block, and
    // output lengths that are not a whole digest.
    test('gives the same bytes as package:cryptography', () async {
      final random = Random(7);
      List<int> bytes(int length) => List.generate(length, (_) => random.nextInt(256));
      for (final keyLength in [0, 1, 32, 64, 65, 100]) {
        for (final saltLength in [0, 16, 51, 52, 56, 64, 100]) {
          for (final (iterations, length) in [(1, 32), (2, 16), (3, 33), (1000, 64)]) {
            final key = bytes(keyLength);
            final salt = bytes(saltLength);
            final expected = await Pbkdf2(
              macAlgorithm: Hmac.sha256(),
              iterations: iterations,
              bits: length * 8,
            ).deriveKey(secretKey: SecretKey(key), nonce: salt);
            expect(
              _hex(pbkdf2HmacSha256(key, salt, iterations, length)),
              _hex(await expected.extractBytes()),
              reason: 'key $keyLength, salt $saltLength, $iterations rounds, $length bytes',
            );
          }
        }
      }
    });
  });
}
