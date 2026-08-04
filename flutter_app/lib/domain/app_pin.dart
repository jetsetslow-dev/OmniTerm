/// App-lock PIN storage and verification, ported from `hashPinForStorage` / `verifyStoredPin` in
/// `ui/AppViewModel.kt`.
///
/// The stored format is unchanged from the Kotlin app, so an upgraded install keeps working with the
/// PIN its owner already set — the same data-compatibility constraint as the legacy credential
/// bridge (§7.10) and the backup envelope. A migration that silently invalidated everyone's PIN
/// would lock them out of their own hosts.
///
/// ```
/// pin:v2:<iterations>:<base64 salt>:<base64 hash>:<pin length>
/// ```
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const pinHashV1Prefix = 'pin:v1:';
const pinHashV2Prefix = 'pin:v2:';

/// PBKDF2 rounds for a newly set PIN.
///
/// A PIN is four to eight digits — a search space small enough to exhaust in seconds without a
/// deliberate work factor. The iteration count is the only thing making an offline attack on a
/// stolen database cost anything at all.
const pinPbkdf2Iterations = 210000;

/// Iteration bounds accepted when reading a stored hash.
///
/// A stored record is not trusted to name its own work factor: a value of 1 written by an attacker
/// (or by corruption) would make verification instant, and a value of a billion would hang the
/// unlock screen. Same shape as the backup envelope's KDF range check.
const pinMinIterations = 100000;
const pinMaxIterations = 1000000;

const pinSaltBytes = 16;
const pinHashBytes = 32;

/// Failed attempts before entry is throttled, and for how long.
const pinMaxAttempts = 5;
const pinLockoutMs = 30000;

/// True while PIN entry is throttled after too many failures.
bool isPinThrottled(int lockedUntilMs, int nowMs) => nowMs < lockedUntilMs;

/// The lockout deadline after a failed attempt, or 0 when no lockout applies.
int pinLockoutAfterFailure(int failedAttempts, int nowMs) =>
    failedAttempts >= pinMaxAttempts ? nowMs + pinLockoutMs : 0;

/// The PIN's length as recorded alongside its hash, or null when unknown.
///
/// Stored so the entry screen can show the right number of slots without holding the PIN itself.
int? storedPinLength(String? stored) {
  if (stored == null) return null;
  if (!stored.startsWith(pinHashV1Prefix) && !stored.startsWith(pinHashV2Prefix)) return null;
  final tail = stored.split(':').last;
  return int.tryParse(tail);
}

/// True when [stored] is a hash this app wrote, rather than a plaintext PIN from a very old build.
bool isHashedPin(String? stored) => stored != null && stored.startsWith('pin:');

/// Hash [pin] for storage.
Future<String> hashPinForStorage(String pin, {Random? random}) async {
  final rng = random ?? Random.secure();
  final salt = Uint8List.fromList(List.generate(pinSaltBytes, (_) => rng.nextInt(256)));
  final hash = await _derive(pin, salt, pinPbkdf2Iterations);
  return [
    'pin',
    'v2',
    '$pinPbkdf2Iterations',
    base64.encode(salt),
    base64.encode(hash),
    '${pin.length}',
  ].join(':');
}

/// Check [pin] against a stored record.
///
/// Returns false for anything malformed rather than throwing: a corrupt row must produce "wrong
/// PIN", never a crash on the one screen standing between a thief and the host list.
Future<bool> verifyStoredPin(String? stored, String pin) async {
  if (stored == null || stored.trim().isEmpty || pin.isEmpty) return false;

  // A pre-hash build stored the PIN in the clear. Still accepted so those users can get in and be
  // upgraded on success — see [pinNeedsRehash].
  if (!stored.startsWith('pin:')) return _constantTimeEquals(utf8.encode(stored), utf8.encode(pin));

  final parts = stored.split(':');
  try {
    if (stored.startsWith(pinHashV2Prefix) && parts.length == 6) {
      final iterations = int.tryParse(parts[2]);
      if (iterations == null || iterations < pinMinIterations || iterations > pinMaxIterations) {
        return false;
      }
      final salt = base64.decode(parts[3]);
      final expected = base64.decode(parts[4]);
      if (salt.length != pinSaltBytes || expected.length != pinHashBytes) return false;
      return _constantTimeEquals(expected, await _derive(pin, salt, iterations));
    }

    if (stored.startsWith(pinHashV1Prefix) && parts.length == 5) {
      // The original scheme: a single unsalted-work-factor SHA-256 over salt+pin. Accepted only so
      // an existing user can sign in; [pinNeedsRehash] then upgrades them to v2.
      final salt = base64.decode(parts[2]);
      final expected = base64.decode(parts[3]);
      final actual = await Sha256().hash([...salt, ...utf8.encode(pin)]);
      return _constantTimeEquals(expected, actual.bytes);
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// True when a successful verification should be followed by re-storing the PIN at the current
/// scheme — a plaintext PIN, a v1 hash, or a v2 hash written with fewer rounds than we now use.
bool pinNeedsRehash(String? stored) {
  if (stored == null || stored.trim().isEmpty) return false;
  if (!stored.startsWith('pin:')) return true;
  if (stored.startsWith(pinHashV1Prefix)) return true;
  if (!stored.startsWith(pinHashV2Prefix)) return true;
  final iterations = int.tryParse(stored.split(':').elementAtOrNull(2) ?? '');
  return iterations == null || iterations < pinPbkdf2Iterations;
}

Future<List<int>> _derive(String pin, List<int> salt, int iterations) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: pinHashBytes * 8,
  );
  final key = await pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(pin)),
    nonce: salt,
  );
  return key.extractBytes();
}

/// Length-independent comparison.
///
/// Not because a PIN hash is worth a timing attack on its own, but because the same helper is the
/// one used for the plaintext-legacy path, where an early-exit compare leaks the PIN digit by digit.
bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
