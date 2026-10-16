/// Preparing an imported SSH key for storage, ported from `addSshKey` and its helpers in
/// `ui/AppViewModel.kt`.
///
/// Kept out of the view model because it is the point where unusable key material must be rejected:
/// a key that fails to parse here would otherwise be saved happily and only fail at connect time,
/// where the error is cryptic and arrives when the user is trying to do something else.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/ssh/ssh_private_key.dart';

/// A key that has been validated and is ready to store.
class ImportedKey {
  const ImportedKey({
    required this.alias,
    required this.keyType,
    required this.privateKey,
    required this.publicKey,
    required this.fingerprint,
  });

  final String alias;
  final String keyType;
  final String privateKey;

  /// The OpenSSH public line, or "" when it could not be derived.
  final String publicKey;

  final String fingerprint;
}

/// Why an import was refused. Carries a message meant to be shown verbatim.
class KeyImportException implements Exception {
  const KeyImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Validates and normalises an imported key.
///
/// Only [privateKey] is required: [publicKey] is optional and [keyType] is detected when blank,
/// because a user pasting a key from `~/.ssh` usually has only the private half to hand.
///
/// [existingAliases] must be the aliases already stored — an alias is how a host names its key, so a
/// duplicate would make it ambiguous which key a host actually uses.
ImportedKey prepareKeyImport({
  required String alias,
  required String privateKey,
  String publicKey = '',
  String keyType = '',
  Set<String> existingAliases = const {},
}) {
  final trimmedAlias = alias.trim();
  if (trimmedAlias.isEmpty) {
    throw const KeyImportException('Key alias is required.');
  }
  if (existingAliases.contains(trimmedAlias)) {
    throw const KeyImportException('Key alias already exists.');
  }

  final private = privateKey.trim();
  if (private.isEmpty) {
    throw const KeyImportException('Private key content is required.');
  }

  // Reject unparseable material up front, with the parser's own reason. Storing it and failing at
  // connect time buries the cause.
  final parseError = privateKeyParseError(private);
  if (parseError != null) throw KeyImportException(parseError);

  final public = publicKey.trim();
  final usablePublic = isPublicKeyLine(public) ? public : '';
  final resolvedType = keyType.trim().isNotEmpty
      ? keyType.trim()
      : detectKeyType(private, usablePublic);

  return ImportedKey(
    alias: trimmedAlias,
    keyType: resolvedType,
    privateKey: private,
    publicKey: usablePublic,
    // The public key is what OpenSSH itself fingerprints, so `ssh-keygen -lf` on the host prints the
    // same string — which is the whole point of showing one. Without it, hashing the private
    // material at least gives a stable identifier for spotting duplicates.
    fingerprint: usablePublic.isNotEmpty
        ? sshPublicKeyFingerprint(usablePublic)
        : keyMaterialFingerprint(private),
  );
}

/// True when [line] looks like an OpenSSH public key line (`ssh-ed25519 AAAA… comment`).
bool isPublicKeyLine(String line) {
  final trimmed = line.trim();
  return trimmed.startsWith('ssh-') || trimmed.startsWith('ecdsa-');
}

/// Best-effort key-type label for display.
///
/// The public line is preferred because it names the algorithm outright. A private key only helps
/// for the legacy PEM headers: a modern `BEGIN OPENSSH PRIVATE KEY` container does not reveal its
/// inner type without parsing, which is why that case reports the container rather than guessing.
String detectKeyType(String privateKey, String publicKey) {
  if (publicKey.startsWith('ssh-ed25519')) return 'ED25519';
  if (publicKey.startsWith('ecdsa-')) return 'ECDSA';
  if (publicKey.startsWith('ssh-rsa')) return 'RSA';
  if (publicKey.startsWith('ssh-dss')) return 'DSA';
  if (privateKey.contains('BEGIN RSA PRIVATE KEY')) return 'RSA';
  if (privateKey.contains('BEGIN EC PRIVATE KEY')) return 'ECDSA';
  if (privateKey.contains('BEGIN DSA PRIVATE KEY')) return 'DSA';
  if (privateKey.contains('BEGIN OPENSSH PRIVATE KEY')) return 'OpenSSH';
  return 'SSH Key';
}

/// The OpenSSH SHA-256 fingerprint of a public key line.
///
/// Hashes the **decoded** base64 blob, not the text, so it matches `ssh-keygen -lf` exactly — a
/// fingerprint the user can compare against one the server printed. The trailing base64 padding is
/// stripped, as OpenSSH does.
String sshPublicKeyFingerprint(String publicKey) {
  final parts = publicKey.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return keyMaterialFingerprint(publicKey);
  try {
    final blob = base64.decode(parts[1]);
    return 'SHA256:${_base64NoPadding(sha256.convert(blob).bytes)}';
  } on FormatException {
    // Not valid base64, so it is not really a public key line; fall back rather than throwing —
    // a bad fingerprint is cosmetic, whereas refusing the import would not be.
    return keyMaterialFingerprint(publicKey);
  }
}

/// A stable identifier for material that is not an OpenSSH public line.
///
/// Not comparable with anything the server prints — it exists only so every stored key has *some*
/// fingerprint, which is what makes duplicates visible in the list.
String keyMaterialFingerprint(String keyMaterial) =>
    'SHA256:${_base64NoPadding(sha256.convert(utf8.encode(keyMaterial)).bytes)}';

String _base64NoPadding(List<int> bytes) => base64.encode(bytes).replaceAll(RegExp(r'=+$'), '');
