/// Generating a new SSH keypair on the device, ported from `generateSshKey` in `ui/AppViewModel.kt`.
///
/// Kotlin delegates to JSch's `KeyPair.genKeyPair`, which has no Dart equivalent, so the encoding is
/// done here: PointyCastle produces the RSA parameters and this file writes the two formats OpenSSH
/// actually consumes — a PKCS#1 PEM private key and an `ssh-rsa` public line. Both are byte-for-byte
/// what `ssh-keygen` would have written, which matters because the user is told to paste the public
/// line into `~/.ssh/authorized_keys`: anything else fails on the server with no useful diagnostic.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'ssh_key_import.dart';

/// A freshly generated keypair, in the encodings OpenSSH expects.
class GeneratedSshKey {
  const GeneratedSshKey({
    required this.keyType,
    required this.privateKey,
    required this.publicKey,
    required this.fingerprint,
  });

  /// The stored type label, e.g. "RSA".
  final String keyType;

  /// PKCS#1 PEM, `-----BEGIN RSA PRIVATE KEY-----`.
  final String privateKey;

  /// The OpenSSH public line, `ssh-rsa AAAA… <alias>`.
  final String publicKey;

  /// The SHA-256 fingerprint of [publicKey], matching `ssh-keygen -lf`.
  final String fingerprint;
}

/// Why generation was refused. Carries a message meant to be shown verbatim.
class KeyGenerationException implements Exception {
  const KeyGenerationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The key types this build can generate.
///
/// Only RSA, matching Kotlin: JSch could generate RSA and DSA, and DSA is obsolete. Ed25519 is
/// deliberately absent rather than silently downgraded — a user who wants one is told to import it,
/// which is honest, instead of being handed an RSA key under an Ed25519 label.
const List<String> generatableKeyTypes = <String>['RSA'];

/// The modulus size used for generated RSA keys, matching Kotlin's `genKeyPair(…, 4096)`.
const int rsaKeyBits = 4096;

/// Validates the request and generates the keypair.
///
/// [existingAliases] must be the aliases already stored: an alias is how a host names its key, so a
/// duplicate would make it ambiguous which key a host actually uses. Mirrors the same guard in
/// [prepareKeyImport].
///
/// This is CPU-bound for several seconds at 4096 bits. Callers on the UI isolate should run it
/// through `compute`, which is why it is a top-level function taking a single argument shape.
///
/// [bits] exists so tests can generate a throwaway key in milliseconds; production callers leave it
/// at [rsaKeyBits]. Anything below 2048 is unsafe for real use.
GeneratedSshKey generateSshKeyPair({
  required String alias,
  String keyType = 'RSA',
  Set<String> existingAliases = const {},
  SecureRandom? random,
  int bits = rsaKeyBits,
}) {
  final trimmedAlias = alias.trim();
  if (trimmedAlias.isEmpty) {
    throw const KeyGenerationException('Key alias is required.');
  }
  if (existingAliases.contains(trimmedAlias)) {
    throw const KeyGenerationException('Key alias already exists.');
  }

  final normalisedType = keyType.trim().toUpperCase();
  if (!generatableKeyTypes.contains(normalisedType)) {
    // Kotlin's wording, kept verbatim: it tells the user the workaround rather than only refusing.
    throw KeyGenerationException(
      '$keyType key generation is not supported by the bundled SSH library. '
      'Import an existing key instead.',
    );
  }

  final pair = _generateRsaPair(random ?? _seededRandom(), bits);
  final public = pair.publicKey as RSAPublicKey;
  final private = pair.privateKey as RSAPrivateKey;

  final publicLine = encodeOpenSshRsaPublicKey(public, comment: trimmedAlias);
  return GeneratedSshKey(
    keyType: normalisedType,
    privateKey: encodePkcs1PrivateKeyPem(private),
    publicKey: publicLine,
    fingerprint: sshPublicKeyFingerprint(publicLine),
  );
}

AsymmetricKeyPair<PublicKey, PrivateKey> _generateRsaPair(SecureRandom random, int bits) {
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        // 65537: the exponent every SSH implementation expects. Smaller exponents have a history of
        // padding attacks and some servers reject them outright.
        RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
        random,
      ),
    );
  return generator.generateKeyPair();
}

/// A CSPRNG seeded from the platform's entropy source.
///
/// Fortuna needs 32 seed bytes; `Random.secure()` is the only cross-platform source Dart exposes.
/// Seeding from anything predictable here would silently produce guessable private keys, so this is
/// deliberately not a plain `Random()`.
SecureRandom _seededRandom() {
  final seedSource = Random.secure();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => seedSource.nextInt(256)),
  );
  return FortunaRandom()..seed(KeyParameter(seed));
}

/// Encodes an RSA public key as the single-line OpenSSH format.
///
/// The blob is the SSH wire encoding — the algorithm name, then `e`, then `n`, each length-prefixed —
/// base64'd and prefixed with the algorithm name again. [comment] becomes the trailing label OpenSSH
/// shows in `authorized_keys`.
String encodeOpenSshRsaPublicKey(RSAPublicKey key, {String comment = ''}) {
  final blob = BytesBuilder()
    ..add(_sshString(ascii.encode('ssh-rsa')))
    ..add(_sshString(_sshMpint(key.exponent!)))
    ..add(_sshString(_sshMpint(key.modulus!)));
  final encoded = base64.encode(blob.toBytes());
  final trimmedComment = comment.trim();
  return trimmedComment.isEmpty ? 'ssh-rsa $encoded' : 'ssh-rsa $encoded $trimmedComment';
}

/// Encodes an RSA private key as a PKCS#1 PEM block.
///
/// This is the `BEGIN RSA PRIVATE KEY` container JSch wrote, so keys generated by either
/// implementation are interchangeable — and it is what [privateKeyParseError] already accepts.
String encodePkcs1PrivateKeyPem(RSAPrivateKey key) {
  final n = key.modulus!;
  final e = key.publicExponent!;
  final d = key.privateExponent!;
  final p = key.p!;
  final q = key.q!;
  // The CRT parameters. OpenSSH tolerates their absence but every real key carries them, and
  // omitting them makes some tooling recompute the key on every use.
  final exponent1 = d % (p - BigInt.one);
  final exponent2 = d % (q - BigInt.one);
  final coefficient = q.modInverse(p);

  final sequence = _derSequence(<Uint8List>[
    _derInteger(BigInt.zero), // version
    _derInteger(n),
    _derInteger(e),
    _derInteger(d),
    _derInteger(p),
    _derInteger(q),
    _derInteger(exponent1),
    _derInteger(exponent2),
    _derInteger(coefficient),
  ]);

  final body = base64.encode(sequence);
  final wrapped = StringBuffer();
  for (var i = 0; i < body.length; i += 64) {
    wrapped.writeln(body.substring(i, min(i + 64, body.length)));
  }
  return '-----BEGIN RSA PRIVATE KEY-----\n$wrapped-----END RSA PRIVATE KEY-----\n';
}

/// The SSH wire encoding of a byte string: a 32-bit big-endian length, then the bytes.
Uint8List _sshString(List<int> bytes) {
  final out = BytesBuilder()
    ..add(<int>[
      (bytes.length >> 24) & 0xff,
      (bytes.length >> 16) & 0xff,
      (bytes.length >> 8) & 0xff,
      bytes.length & 0xff,
    ])
    ..add(bytes);
  return out.toBytes();
}

/// The SSH `mpint` encoding of a positive integer.
///
/// Two's-complement with a leading zero byte whenever the top bit is set, otherwise the value would
/// read as negative. Only positive values occur here, so the negative branch is not modelled.
Uint8List _sshMpint(BigInt value) {
  final bytes = _bigIntToBytes(value);
  if (bytes.isNotEmpty && (bytes.first & 0x80) != 0) {
    return Uint8List.fromList(<int>[0, ...bytes]);
  }
  return bytes;
}

/// DER `INTEGER`, which uses the same leading-zero rule as `mpint`.
Uint8List _derInteger(BigInt value) {
  final content = value == BigInt.zero ? Uint8List.fromList(<int>[0]) : _sshMpint(value);
  return Uint8List.fromList(<int>[0x02, ..._derLength(content.length), ...content]);
}

Uint8List _derSequence(List<Uint8List> elements) {
  final body = BytesBuilder();
  for (final element in elements) {
    body.add(element);
  }
  final content = body.toBytes();
  return Uint8List.fromList(<int>[0x30, ..._derLength(content.length), ...content]);
}

/// DER length: short form below 128, otherwise a byte count followed by big-endian bytes.
List<int> _derLength(int length) {
  if (length < 0x80) return <int>[length];
  final bytes = <int>[];
  var remaining = length;
  while (remaining > 0) {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  return <int>[0x80 | bytes.length, ...bytes];
}

/// Big-endian bytes of a non-negative [BigInt], with no leading zero padding.
Uint8List _bigIntToBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List(0);
  final bytes = <int>[];
  var remaining = value;
  final mask = BigInt.from(0xff);
  while (remaining > BigInt.zero) {
    bytes.insert(0, (remaining & mask).toInt());
    remaining >>= 8;
  }
  return Uint8List.fromList(bytes);
}

/// The command that installs [publicKey] into the logged-in user's `authorized_keys`.
///
/// Shown after generation and copyable, because a generated key is useless until the server has the
/// public half. Kept identical to Kotlin's string so the documented instructions stay true.
String authorizedKeysInstallCommand(String publicKey) =>
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${publicKey.trim()}' >> "
    '~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys';
