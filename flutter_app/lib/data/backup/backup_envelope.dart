/// The encrypted backup envelope: AES-256-GCM over gzipped JSON, keyed from a passphrase by PBKDF2.
///
/// The wire format is deliberately unchanged from the Android app, so a backup taken there restores
/// here. That is data compatibility for a real user's file, not historical residue (§16.4):
///
/// ```json
/// { "v": 2, "compression": "gzip", "kdf": "PBKDF2WithHmacSHA256",
///   "iterations": 600000, "salt": "…", "iv": "…", "data": "…" }
/// ```
///
/// **A wrong passphrase fails the GCM tag check and is reported as a wrong passphrase.** That is the
/// whole point of using an authenticated cipher here: without the tag, a bad key would decrypt to
/// garbage that then fails to parse as JSON, and the user would be told their file was corrupt.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Raised for a backup that cannot be read, with a message meant for the user.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Limits that bound what a restore will attempt.
///
/// A backup file is untrusted input — it can arrive from a cloud drive, a chat message, or an
/// attacker. Every one of these exists to stop a crafted file exhausting memory before its contents
/// are ever examined.
class BackupLimits {
  const BackupLimits._();

  /// Largest file accepted, before any parsing.
  static const maxInputChars = 20 * 1024 * 1024;

  static const maxCiphertextBytes = 12 * 1024 * 1024;

  /// Largest plaintext a restore will decompress to.
  static const maxPlainBytes = 32 * 1024 * 1024;

  /// How far gzip may expand its input. A zip bomb is a small file that decompresses to gigabytes;
  /// the ratio is what catches one before the absolute cap does.
  static const maxExpansionRatio = 200;

  /// Nesting depth accepted in the JSON. Deeply nested input is the standard way to blow a
  /// recursive-descent parser's stack.
  static const maxJsonDepth = 24;

  /// PBKDF2 work factor written by this app.
  static const kdfIterations = 600000;

  /// Accepted range when reading someone else's envelope.
  ///
  /// The floor stops a crafted file specifying one iteration and making an offline guess of the
  /// passphrase cheap. The ceiling stops one specifying a billion and wedging the device.
  static const minKdfIterations = 100000;
  static const maxKdfIterations = 1000000;

  static const saltBytes = 16;
  static const ivBytes = 12;
}

/// Encrypts [json] under [passphrase].
Future<String> encryptBackup(String json, String passphrase) async {
  if (passphrase.isEmpty) {
    throw const BackupException('A passphrase is required to encrypt a backup.');
  }

  final compressed = Uint8List.fromList(gzip.encode(utf8.encode(json)));
  final random = Random.secure();
  final salt = Uint8List.fromList(
    List.generate(BackupLimits.saltBytes, (_) => random.nextInt(256)),
  );

  final secretKey = await _deriveKey(passphrase, salt, BackupLimits.kdfIterations);
  final box = await AesGcm.with256bits().encrypt(compressed, secretKey: secretKey);

  return jsonEncode({
    'v': 2,
    'compression': 'gzip',
    'kdf': 'PBKDF2WithHmacSHA256',
    'iterations': BackupLimits.kdfIterations,
    'salt': base64.encode(salt),
    'iv': base64.encode(box.nonce),
    // The GCM tag is appended to the ciphertext, matching how the Android envelope was written.
    'data': base64.encode([...box.cipherText, ...box.mac.bytes]),
  });
}

/// Decrypts an envelope produced by [encryptBackup], returning the JSON it carried.
Future<String> decryptBackup(String envelopeText, String passphrase) async {
  if (envelopeText.length > BackupLimits.maxInputChars) {
    throw const BackupException('That backup file is too large to open.');
  }
  _assertJsonDepth(envelopeText);

  final Map<String, dynamic> envelope;
  try {
    envelope = jsonDecode(envelopeText) as Map<String, dynamic>;
  } catch (_) {
    throw const BackupException('That does not look like an OmniTerm backup.');
  }

  for (final field in ['salt', 'iv', 'data']) {
    if (envelope[field] is! String) {
      throw const BackupException('That backup file is missing required fields.');
    }
  }
  if (envelope['compression'] != 'gzip') {
    throw const BackupException('That backup uses a compression this version cannot read.');
  }
  if ((envelope['data'] as String).length > BackupLimits.maxInputChars) {
    throw const BackupException('That backup file is too large to open.');
  }

  final Uint8List salt;
  final Uint8List iv;
  final Uint8List payload;
  try {
    salt = base64.decode(envelope['salt'] as String);
    iv = base64.decode(envelope['iv'] as String);
    payload = base64.decode(envelope['data'] as String);
  } on FormatException {
    throw const BackupException('That backup file is damaged.');
  }

  final iterations = envelope['iterations'] is int ? envelope['iterations'] as int : -1;
  validateCryptoParameters(
    iterations: iterations,
    saltSize: salt.length,
    ivSize: iv.length,
    ciphertextSize: payload.length,
  );

  // The last 16 bytes are the GCM tag.
  final cipherText = payload.sublist(0, payload.length - 16);
  final mac = Mac(payload.sublist(payload.length - 16));

  final secretKey = await _deriveKey(passphrase, salt, iterations);
  final List<int> compressed;
  try {
    compressed = await AesGcm.with256bits().decrypt(
      SecretBox(cipherText, nonce: iv, mac: mac),
      secretKey: secretKey,
    );
  } on SecretBoxAuthenticationError {
    // The authenticated cipher is what makes this answerable. Without the tag the user would be
    // told their file was corrupt when the passphrase was simply wrong.
    throw const BackupException('That passphrase does not match this backup file.');
  }

  final json = utf8.decode(gunzipBounded(Uint8List.fromList(compressed)));
  _assertJsonDepth(json);
  return json;
}

/// Checks the crypto parameters an untrusted envelope declares.
void validateCryptoParameters({
  required int iterations,
  required int saltSize,
  required int ivSize,
  required int ciphertextSize,
  int maxCiphertextBytes = BackupLimits.maxCiphertextBytes,
}) {
  if (iterations < BackupLimits.minKdfIterations || iterations > BackupLimits.maxKdfIterations) {
    throw const BackupException(
      'That backup declares an unsafe key-derivation strength and was not opened.',
    );
  }
  if (saltSize != BackupLimits.saltBytes) {
    throw const BackupException('That backup file is damaged (bad salt).');
  }
  if (ivSize != BackupLimits.ivBytes) {
    throw const BackupException('That backup file is damaged (bad IV).');
  }
  // Below 16 bytes there is not even a GCM tag, so there is nothing to authenticate.
  if (ciphertextSize < 16 || ciphertextSize > maxCiphertextBytes) {
    throw const BackupException('That backup file is damaged (bad length).');
  }
}

/// Decompresses [bytes], refusing anything that expands beyond the safe limits.
Uint8List gunzipBounded(
  Uint8List bytes, {
  int maxPlainBytes = BackupLimits.maxPlainBytes,
  int maxCompressedBytes = BackupLimits.maxCiphertextBytes,
  int maxExpansionRatio = BackupLimits.maxExpansionRatio,
}) {
  if (bytes.length > maxCompressedBytes) {
    throw const BackupException('That backup file is too large to open.');
  }

  // The ratio catches a bomb long before the absolute cap would, but a small legitimate backup
  // compresses well too — hence the 1 MB floor, below which the ratio is not meaningful.
  final ratioLimit = min(
    maxPlainBytes,
    max(bytes.length * maxExpansionRatio, min(1024 * 1024, maxPlainBytes)),
  );

  final Uint8List decoded;
  try {
    decoded = Uint8List.fromList(gzip.decode(bytes));
  } catch (_) {
    throw const BackupException('That backup file is damaged.');
  }
  if (decoded.length > ratioLimit || decoded.length > maxPlainBytes) {
    throw const BackupException('That backup expands beyond the safe restore limit.');
  }
  return decoded;
}

/// Rejects JSON nested deeply enough to threaten the parser's stack.
///
/// Counted over the raw text before decoding, because by the time a parser has recursed far enough
/// to matter it has already done the damage.
void _assertJsonDepth(String text, {int maxDepth = BackupLimits.maxJsonDepth}) {
  var depth = 0;
  var inString = false;
  var escaped = false;

  for (final rune in text.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (rune == 0x5C) {
        escaped = true;
      } else if (rune == 0x22) {
        inString = false;
      }
      continue;
    }
    switch (rune) {
      case 0x22: // "
        inString = true;
      case 0x7B: // {
      case 0x5B: // [
        depth++;
        if (depth > maxDepth) {
          throw const BackupException('That backup file is nested too deeply to be read safely.');
        }
      case 0x7D: // }
      case 0x5D: // ]
        depth--;
    }
  }
}

Future<SecretKey> _deriveKey(String passphrase, Uint8List salt, int iterations) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  return pbkdf2.deriveKeyFromPassword(password: passphrase, nonce: salt);
}
