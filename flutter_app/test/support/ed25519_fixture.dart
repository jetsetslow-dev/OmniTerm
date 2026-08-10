import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A throwaway Ed25519 keypair, generated fresh for whichever test asked for it.
///
/// The tests that need one used to carry a committed `BEGIN OPENSSH PRIVATE KEY` block. Those keys
/// authenticated to nothing, but a secret-shaped literal in the tree is indistinguishable from a
/// real leak to any scanner, and the repository's secret gate scans **all history** — so every
/// commit that touched one of those files kept reporting a finding forever.
///
/// Generating instead of embedding means there is no key material to find, and no judgement call
/// for a future reader about whether a given block is "the safe one". It also makes the fixture
/// stronger: the parser is handed bytes it has never seen before on every run, rather than the one
/// blob it was originally written against.
class Ed25519Fixture {
  const Ed25519Fixture({required this.privateKey, required this.publicKey});

  /// An unencrypted OpenSSH-format private key, exactly as `ssh-keygen -t ed25519` writes one.
  final String privateKey;

  /// The matching `ssh-ed25519 <base64> <comment>` line.
  final String publicKey;
}

/// A PEM banner, assembled rather than written out.
///
/// Tests that check how a *marker* is classified do not need key material, but a literal
/// `-----BEGIN RSA PRIVATE KEY-----` in the source is reported by any secret scanner, and the
/// repository's gate scans all history — so once such a line is committed it is flagged in that
/// commit forever, and a fingerprint suppression has to be added for every future commit that
/// touches the file. Building the banner at runtime avoids creating the problem in the first place.
/// This follows the precedent already set for `CrashLogRedactionTest` (see `.gitleaksignore`).
String pemBegin(String kind) => '-----BEGIN $kind PRIVATE KEY-----';

/// The closing banner matching [pemBegin].
String pemEnd(String kind) => '-----END $kind PRIVATE KEY-----';

Ed25519Fixture? _shared;

/// One fixture per test file, generated on first use.
///
/// Each test file runs in its own isolate, so this memoises within a file rather than across the
/// suite. That is the intent: a file's tests should agree on the key they are importing and
/// re-importing, or "this alias already exists" stops meaning anything.
Future<Ed25519Fixture> sharedEd25519Fixture() async =>
    _shared ??= await generateEd25519Fixture();

/// Generates a fresh Ed25519 keypair and serialises it the way OpenSSH does.
///
/// [comment] is embedded in both halves, as `ssh-keygen` embeds the user@host it was run on.
Future<Ed25519Fixture> generateEd25519Fixture({
  String comment = 'test@omniterm.test',
}) async {
  final pair = await Ed25519().newKeyPair();
  final seed = Uint8List.fromList(await pair.extractPrivateKeyBytes());
  final public = Uint8List.fromList((await pair.extractPublicKey()).bytes);

  return Ed25519Fixture(
    privateKey: _encodeOpenSshPrivateKey(
      seed: seed,
      public: public,
      comment: comment,
    ),
    publicKey:
        'ssh-ed25519 ${base64.encode(_publicBlob(public))} $comment',
  );
}

/// The `ssh-ed25519` public key blob: the algorithm name followed by the 32 raw public bytes.
Uint8List _publicBlob(Uint8List public) => _wire([
  _string('ssh-ed25519'),
  _bytes(public),
]);

/// Serialises an unencrypted private key in OpenSSH's own container format.
///
/// The layout is `PROTOCOL.key` from the OpenSSH source:
///
/// ```
/// "openssh-key-v1\0" | ciphername | kdfname | kdfoptions | count | pubkey | encrypted block
/// ```
///
/// With no passphrase the cipher and KDF are both the literal string `none` and the "encrypted"
/// block is stored in the clear — which is what makes this reproducible without a crypto backend
/// for bcrypt_pbkdf.
String _encodeOpenSshPrivateKey({
  required Uint8List seed,
  required Uint8List public,
  required String comment,
}) {
  // Two identical check integers; a decrypter that reads a passphrase compares them to tell a wrong
  // passphrase from a corrupt file. Unencrypted, any value works, but a real one keeps the fixture
  // honest against a parser that validates them.
  final check = Random.secure().nextInt(0xFFFFFFFF);

  final privateSection = <Uint8List>[
    _uint32(check),
    _uint32(check),
    _string('ssh-ed25519'),
    _bytes(public),
    // OpenSSH stores the 64-byte "private key" as seed ‖ public, not the seed alone.
    _bytes(Uint8List.fromList([...seed, ...public])),
    _string(comment),
  ];

  // Padded to the cipher block size with the bytes 1, 2, 3… — 8 even for `none`.
  final body = _wire(privateSection);
  final padded = BytesBuilder()..add(body);
  for (var i = 1; padded.length % 8 != 0; i++) {
    padded.addByte(i);
  }

  final container = BytesBuilder()
    ..add(utf8.encode('openssh-key-v1'))
    ..addByte(0)
    ..add(_string('none'))
    ..add(_string('none'))
    ..add(_string(''))
    ..add(_uint32(1))
    ..add(_bytes(_publicBlob(public)))
    ..add(_bytes(padded.toBytes()));

  final encoded = base64.encode(container.toBytes());
  final lines = <String>[
    for (var i = 0; i < encoded.length; i += 70)
      encoded.substring(i, min(i + 70, encoded.length)),
  ];
  return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
      '${lines.join('\n')}\n'
      '-----END OPENSSH PRIVATE KEY-----';
}

Uint8List _wire(List<Uint8List> parts) {
  final out = BytesBuilder();
  for (final part in parts) {
    out.add(part);
  }
  return out.toBytes();
}

/// An SSH wire string: a big-endian length followed by the bytes.
Uint8List _bytes(Uint8List value) =>
    Uint8List.fromList([..._uint32(value.length), ...value]);

Uint8List _string(String value) => _bytes(Uint8List.fromList(utf8.encode(value)));

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);
