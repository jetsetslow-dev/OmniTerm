import 'package:dartssh2/dartssh2.dart';

/// Private-key validation and parsing, ported from `addPrivateKeyIdentity` in
/// `data/ssh/JschSession.kt`.
///
/// The value here is entirely in the diagnostics. JSch threw
/// `JSchException("invalid privatekey: " + byte[])` on an unparseable key, and the array rendered as
/// `[B@1a2b3c` — which is what reached the UI. dartssh2 throws its own errors, so the same guards
/// are applied *before* parsing and the same fallback message afterwards, because "invalid key" with
/// no hint is the single most common support question for an SSH client.

/// Raised for a key the user can fix by pasting something different.
class InvalidPrivateKeyException implements Exception {
  InvalidPrivateKeyException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

const _publicKeyPrefixes = ['ssh-rsa ', 'ssh-ed25519 ', 'ecdsa-sha2-', 'ssh-dss '];

/// Parses [privateKey] into the identities dartssh2 authenticates with.
///
/// Throws [InvalidPrivateKeyException] with an actionable message rather than surfacing a parser's
/// internal representation.
List<SSHKeyPair> parsePrivateKey(String privateKey, {String? passphrase}) {
  final trimmed = privateKey.trim();

  // Wrong half of the pair: a public key was pasted into the private-key field. Worth its own
  // message because the two files sit side by side and differ only by a .pub suffix.
  if (_publicKeyPrefixes.any(trimmed.startsWith)) {
    throw InvalidPrivateKeyException(
      'That looks like a public key. Paste the matching PRIVATE key — the file without '
      'the .pub extension, starting with "-----BEGIN ... PRIVATE KEY-----".',
    );
  }

  if (!trimmed.contains('PRIVATE KEY')) {
    throw InvalidPrivateKeyException(
      "That doesn't look like a private key. Paste the full key including the "
      '"-----BEGIN ... PRIVATE KEY-----" and "-----END ... PRIVATE KEY-----" lines.',
    );
  }

  // Unify line endings and guarantee a trailing newline. PEM parsers are picky about it, and
  // pasting on a phone often introduces CRLF or strips the final newline.
  final normalized = '${trimmed.replaceAll('\r\n', '\n').replaceAll('\r', '\n')}\n';

  try {
    return SSHKeyPair.fromPem(normalized, _blankToNull(passphrase));
  } catch (e) {
    final detail = _usableDetail(e);
    throw InvalidPrivateKeyException(
      detail != null
          ? 'Invalid private key: $detail'
          : 'Invalid private key. If it has a passphrase, enter it; otherwise re-copy the full key.',
      e,
    );
  }
}

/// True when [privateKey] is encrypted and therefore needs a passphrase.
bool privateKeyNeedsPassphrase(String privateKey) {
  try {
    return SSHKeyPair.isEncryptedPem(
      '${privateKey.trim().replaceAll('\r\n', '\n').replaceAll('\r', '\n')}\n',
    );
  } catch (_) {
    return false;
  }
}

String? _blankToNull(String? value) =>
    (value == null || value.trim().isEmpty) ? null : value;

/// Suppresses parser messages that would leak an internal representation instead of explaining
/// anything — the Kotlin filtered JSch's `[B@…` byte-array dump for exactly this reason.
String? _usableDetail(Object error) {
  final text = error.toString().trim();
  if (text.isEmpty) return null;
  if (text.contains('[B@') || text.contains('Instance of')) return null;
  return text;
}

/// The reason [privateKey] cannot be used, or null when it parses.
///
/// Lets a caller reject bad key material at the point the user pastes it, rather than storing it and
/// failing at connect time — where the message arrives while they are trying to do something else
/// and gives no hint that the key was the problem.
///
/// An **encrypted** key is not a failure: it parses once its passphrase is supplied, and the app
/// prompts for that at connect time.
String? privateKeyParseError(String privateKey, {String? passphrase}) {
  if (passphrase == null && privateKeyNeedsPassphrase(privateKey)) return null;
  try {
    parsePrivateKey(privateKey, passphrase: passphrase);
    return null;
  } on InvalidPrivateKeyException catch (e) {
    return e.message;
  } catch (e) {
    return 'Invalid private key.';
  }
}
