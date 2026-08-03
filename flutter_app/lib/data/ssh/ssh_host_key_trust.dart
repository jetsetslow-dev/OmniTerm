/// Trust-on-first-use SSH host-key pinning, ported from `data/ssh/SshHostKeyTrust.kt`.
///
/// ## What changed, and why it is still equivalent
///
/// JSch handed its `HostKeyRepository` the **raw public key blob**, which the Kotlin stored base64
/// encoded. dartssh2's `SSHHostkeyVerifyHandler` is `(String type, Uint8List fingerprint)` — it
/// exposes only the OpenSSH-style SHA-256 fingerprint, and no host at all. So this port:
///
///  1. **Pins the fingerprint** (`SHA256:<base64, unpadded>`) rather than the key blob. That is not
///     a security downgrade: pinning a SHA-256 digest is as strong as pinning the preimage, and it
///     is exactly the value OpenSSH itself shows the user for comparison.
///  2. **Converts legacy pins on read.** An entry stored by the Kotlin app is a base64 public key;
///     [_canonicalFingerprint] derives its fingerprint using the same computation the Kotlin
///     `listKnownHosts` used, so an existing trust store keeps working and no host re-prompts. That
///     matters beyond convenience — re-prompting the whole fleet trains users to click through the
///     one dialog that is supposed to stop an interception.
///  3. **Builds the handler per connection**, closing over host and port, because dartssh2 does not
///     pass them.
///
/// The Kotlin needed `runBlocking` + `withTimeoutOrNull` because JSch called the repository
/// synchronously. dartssh2 awaits the handler, so the approval is a plain `Future` with a timeout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../remote_models.dart';
import 'async_lock.dart';


/// The outcome of checking a presented host key against the trust store.
enum HostKeyVerdict {
  /// Matches the pinned key: proceed.
  ok,

  /// A key is pinned for this host and it is **not** this one. Never auto-accepted.
  changed,

  /// Nothing pinned, and the connection was not approved (no UI, declined, or timed out).
  notIncluded,
}

/// A first-connect approval decision requested from the UI.
class HostKeyApprovalRequest {
  HostKeyApprovalRequest({
    required this.host,
    required this.keyType,
    required this.fingerprint,
    required this.completer,
  });

  final String host;
  final String keyType;

  /// OpenSSH-style `SHA256:…`, shown to the user to compare against the server's own output.
  final String fingerprint;
  final Completer<bool> completer;
}

/// Where pinned keys live. Abstracted so the trust logic is testable without a platform keystore.
abstract interface class HostKeyStore {
  Future<Map<String, String>> readAll();
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
}

/// In-memory store for tests.
class InMemoryHostKeyStore implements HostKeyStore {
  final Map<String, String> _entries = {};

  @override
  Future<Map<String, String>> readAll() async => Map.of(_entries);

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String value) async => _entries[key] = value;

  @override
  Future<void> delete(String key) async => _entries.remove(key);

  @override
  Future<void> deleteAll() async => _entries.clear();
}

class SshHostKeyTrust {
  SshHostKeyTrust(this._store);

  final HostKeyStore _store;
  /// Serialises the read-then-write of a first pin.
  ///
  /// **Genuinely required, unlike the `@Synchronized` annotations elsewhere in the migration.**
  /// Those guarded purely synchronous methods, which cannot interleave on a single-threaded isolate.
  /// Here the store read is `await`ed, so a second connection to the same host can run between this
  /// one's read and its write — exactly the race the Kotlin `synchronized(firstPinCommitLock)`
  /// block existed to close.
  final AsyncLock _firstPinLock = AsyncLock();

  static const approvalTimeout = Duration(seconds: 120);

  Object? _approvalOwner;
  void Function(HostKeyApprovalRequest)? _approvalHandler;

  /// Registration is owner-token based: a retiring ViewModel may clear only its own handler, never a
  /// newer instance's.
  void registerApprovalHandler(Object owner, void Function(HostKeyApprovalRequest) handler) {
    _approvalOwner = owner;
    _approvalHandler = handler;
  }

  void clearApprovalHandler(Object owner) {
    if (identical(_approvalOwner, owner)) {
      _approvalOwner = null;
      _approvalHandler = null;
    }
  }

  // ── storage-key conventions ────────────────────────────────────────────────

  /// Every storage-key alias prefix a given host/port can be pinned under.
  ///
  /// JSch wrote bare `host` for port 22 and `[host]:port` otherwise, and older builds also produced
  /// `host:port`. All three are still recognised so an existing trust store keeps working.
  static Set<String> storageAliases(String host, int port) => {
        host,
        '$host:$port',
        '[$host]:$port',
      };

  /// The alias new pins are written under, matching JSch's own convention.
  static String canonicalAlias(String host, int port) => port == 22 ? host : '[$host]:$port';

  static String _storageKey(String alias, String keyType) => '$alias|$keyType';

  /// Normalises a stored value to an OpenSSH-style fingerprint.
  ///
  /// Values written by this app are already `SHA256:…`. Values inherited from the Kotlin app are a
  /// base64 public key, and are hashed here with the same computation `listKnownHosts` used, so a
  /// migrated trust store verifies without re-prompting.
  static String? _canonicalFingerprint(String? stored) {
    if (stored == null || stored.trim().isEmpty) return null;
    final value = stored.trim();
    if (value.startsWith('SHA256:')) return value;
    try {
      final digest = sha256.convert(base64.decode(value));
      return 'SHA256:${base64.encode(digest.bytes).replaceAll('=', '')}';
    } catch (_) {
      // Unparseable entry: treat as absent rather than as a match. Failing closed here means the
      // user is asked to approve again, never that a corrupt row silently authorises a host.
      return null;
    }
  }

  /// The fingerprint string for a raw public key, matching what dartssh2 reports.
  static String fingerprintOfKey(Uint8List publicKey) {
    final digest = sha256.convert(publicKey);
    return 'SHA256:${base64.encode(digest.bytes).replaceAll('=', '')}';
  }

  /// Decodes the fingerprint dartssh2 passes to its verify handler, which is the UTF-8 bytes of the
  /// `SHA256:<base64>` string rather than the digest itself.
  static String decodeHandlerFingerprint(Uint8List fingerprint) => utf8.decode(fingerprint);

  // ── the trust check ────────────────────────────────────────────────────────

  /// Checks a presented key, prompting for approval when nothing is pinned yet.
  Future<HostKeyVerdict> check({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    final aliases = storageAliases(host, port);
    final all = await _store.readAll();

    // A pin under any alias counts: the same host reached as "nas" and "[nas]:2222" is one host.
    String? pinned;
    for (final entry in all.entries) {
      final parts = entry.key.split('|');
      if (parts.length < 2) continue;
      final entryType = entry.key.substring(parts[0].length + 1);
      if (!aliases.contains(parts[0]) || entryType != keyType) continue;
      final canonical = _canonicalFingerprint(entry.value);
      if (canonical != null) {
        pinned = canonical;
        break;
      }
    }

    if (pinned != null) return pinned == fingerprint ? HostKeyVerdict.ok : HostKeyVerdict.changed;

    final handler = _approvalHandler;
    if (handler == null) {
      // No approval UI available (background worker / early init): fail closed. An unknown host
      // must be trusted interactively before unattended use.
      return HostKeyVerdict.notIncluded;
    }

    final approved = await awaitApproval(
      handler,
      HostKeyApprovalRequest(
        host: host,
        keyType: keyType,
        fingerprint: fingerprint,
        completer: Completer<bool>(),
      ),
    );
    if (!approved) return HostKeyVerdict.notIncluded;

    return persistApprovedFirstPin(
      storageKey: _storageKey(canonicalAlias(host, port), keyType),
      fingerprint: fingerprint,
    );
  }

  /// Bridges the UI decision with a strict deadline.
  ///
  /// Fails closed on timeout, handler failure or a completer that is never answered, so an
  /// unanswered prompt can never leave a connection authorised. Completing the request as rejected
  /// also makes any late UI action a harmless no-op.
  Future<bool> awaitApproval(
    void Function(HostKeyApprovalRequest) handler,
    HostKeyApprovalRequest request, {
    Duration timeout = approvalTimeout,
  }) async {
    if (timeout <= Duration.zero) {
      if (!request.completer.isCompleted) request.completer.complete(false);
      return false;
    }
    try {
      handler(request);
      return await request.completer.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    } finally {
      if (!request.completer.isCompleted) request.completer.complete(false);
    }
  }

  /// Persists a TOFU approval without letting two concurrent first connections replace each other's
  /// key.
  ///
  /// Both may have observed an empty store before showing their dialogs, so the pin is re-read under
  /// the commit lock after approval. The first approved key wins; an identical concurrent key is
  /// accepted, while a different key is reported as changed.
  Future<HostKeyVerdict> persistApprovedFirstPin({
    required String storageKey,
    required String fingerprint,
  }) =>
      _firstPinLock.synchronized(() async {
        final current = _canonicalFingerprint(await _store.read(storageKey));
        if (current == null) {
          await _store.write(storageKey, fingerprint);
          return HostKeyVerdict.ok;
        }
        return current == fingerprint ? HostKeyVerdict.ok : HostKeyVerdict.changed;
      });

  // ── trust-store management ─────────────────────────────────────────────────

  Future<List<KnownHost>> listKnownHosts() async {
    final all = await _store.readAll();
    final out = <KnownHost>[];
    all.forEach((storageKey, rawValue) {
      final fingerprint = _canonicalFingerprint(rawValue);
      if (fingerprint == null) return;
      final sep = storageKey.indexOf('|');
      if (sep <= 0) return;
      out.add(KnownHost(
        storageKey.substring(0, sep),
        storageKey.substring(sep + 1),
        fingerprint,
      ));
    });
    return out;
  }

  /// True when at least one host key (any type) is already pinned for this host.
  Future<bool> hasPinnedKey(String host, int port) async {
    final aliases = storageAliases(host, port);
    final all = await _store.readAll();
    return all.keys.any((key) => aliases.any((alias) => key.startsWith('$alias|')));
  }

  Future<void> removeHost(String host, int port) async {
    final aliases = storageAliases(host, port);
    final all = await _store.readAll();
    for (final key in all.keys) {
      if (aliases.any((alias) => key.startsWith('$alias|'))) {
        await _store.delete(key);
      }
    }
  }

  /// All pinned host keys as storage key (`host|type`) → fingerprint, used by the app backup so a
  /// restored fleet keeps its trust store.
  Future<Map<String, String>> exportEntries() async {
    final all = await _store.readAll();
    final out = <String, String>{};
    all.forEach((key, value) {
      final fingerprint = _canonicalFingerprint(value);
      if (fingerprint != null) out[key] = fingerprint;
    });
    return out;
  }

  /// Import pinned host keys from a backup.
  ///
  /// **Existing pins always win** — a backup must never silently replace a key this device has
  /// already verified, which would turn a restore into an interception vector.
  Future<void> importEntries(Map<String, String> entries) async {
    final existing = await _store.readAll();
    for (final entry in entries.entries) {
      if (!entry.key.contains('|') || entry.value.trim().isEmpty) continue;
      if (existing.containsKey(entry.key)) continue;
      final fingerprint = _canonicalFingerprint(entry.value);
      if (fingerprint != null) await _store.write(entry.key, fingerprint);
    }
  }

  /// Replace the complete trust snapshot, used only to compensate a failed transactional restore.
  Future<void> replaceEntries(Map<String, String> entries) async {
    await _store.deleteAll();
    for (final entry in entries.entries) {
      if (!entry.key.contains('|') || entry.value.trim().isEmpty) continue;
      final fingerprint = _canonicalFingerprint(entry.value);
      if (fingerprint != null) await _store.write(entry.key, fingerprint);
    }
  }

  /// Filter a backup's exported trust entries down to those whose host belongs to one of [hosts].
  ///
  /// Used at restore time so pinned keys are imported only for servers actually restored — orphaned
  /// trust entries for skipped/limited hosts are dropped.
  static Map<String, String> filterEntriesForHosts(
    Map<String, String> entries,
    Iterable<(String host, int port)> hosts,
  ) {
    if (entries.isEmpty) return entries;
    final aliases = <String>{for (final (host, port) in hosts) ...storageAliases(host, port)};
    return {
      for (final entry in entries.entries)
        if (aliases.any((alias) => entry.key.startsWith('$alias|'))) entry.key: entry.value,
    };
  }
}
