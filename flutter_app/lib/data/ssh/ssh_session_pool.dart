import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'async_lock.dart';
import 'ssh_transport.dart';

/// Caches one connected client per (host, port, user, credential) key so repeated one-shot commands
/// reuse a single authenticated connection instead of re-running the full SSH handshake every time.
///
/// Ported from `data/ssh/SshSessionPool.kt`, generic over the client type so the pool can be tested
/// without a real socket.
///
/// **Why this matters:** the telemetry poller fans out to every host on a 15s timer, and the Monitor
/// tabs add their own loops. Without pooling, each cycle re-authenticates to every host — expensive
/// RSA/ed25519 auth, battery drain, and a fast way to trip `MaxStartups`/fail2ban. With pooling we
/// authenticate once per host and keep the connection warm with SSH keepalives.
///
/// Interactive shells are deliberately **not** pooled: they own their own connection lifecycle, and
/// tearing a shell down must never kill a connection shared with exec calls.
class SshSessionPool<C> {
  SshSessionPool({
    required Future<C> Function(SshCredentials creds) connect,
    required bool Function(C client) isAlive,
    required void Function(C client) disconnect,
  })  :
        // Not initializing formals: Dart forbids a named parameter beginning with an underscore,
        // and these callbacks are part of the public constructor API.
        // ignore: prefer_initializing_formals
        _connect = connect,
        // ignore: prefer_initializing_formals
        _isAlive = isAlive,
        // ignore: prefer_initializing_formals
        _disconnect = disconnect;

  final Future<C> Function(SshCredentials) _connect;
  final bool Function(C) _isAlive;
  final void Function(C) _disconnect;

  final Map<String, _Entry<C>> _sessions = {};
  final Map<String, AsyncLock> _locks = {};
  int _lifecycleGeneration = 0;

  /// The pool key.
  ///
  /// It includes a **fingerprint of every secret**, not the secrets themselves, so that changing a
  /// host's password or key produces a different key and cannot reuse the connection authenticated
  /// with the old credentials — while no plaintext secret is ever held as a map key.
  static String poolKey(SshCredentials c) => '${c.username}@${c.host}:${c.port}'
      '|pw=${_fingerprint(c.password)}'
      '|pk=${_fingerprint(c.privateKeyPem)}'
      '|pp=${_fingerprint(c.passphrase)}'
      '|proxy=${c.proxyType}:${c.proxyUser}@${c.proxyHost}:${c.proxyPort}'
      ':${_fingerprint(c.proxyPassword)}'
      ':${_fingerprint(c.proxyKeyPem)}'
      '|ka=${c.keepAliveSeconds}|z=${c.compression}';

  static String _fingerprint(String? secret) {
    if (secret == null || secret.isEmpty) return 'empty';
    final digest = sha256.convert(utf8.encode(secret));
    return digest.bytes
        .take(12)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Return a connected client for [creds], reusing a live cached one or building a new one.
  Future<SshLease<C>> acquire(SshCredentials creds) async {
    final key = poolKey(creds);
    final expectedGeneration = _lifecycleGeneration;
    // Per-key lock so two concurrent callers for the same host don't both open a connection.
    final lock = _locks.putIfAbsent(key, AsyncLock.new);

    return lock.synchronized(() async {
      var entry = _sessions[key];
      final reusable = entry != null &&
          entry.generation == expectedGeneration &&
          !entry.retired &&
          _isAlive(entry.client);

      if (!reusable) {
        final stale = _sessions.remove(key);
        if (stale != null) _retire(stale);
        final client = await _connect(creds);
        try {
          entry = _Entry<C>(client, expectedGeneration);
          _sessions[key] = entry;
        } catch (_) {
          _disconnect(client);
          rethrow;
        }
      }

      final live = entry;
      // Take the lease before revalidating. If closeAll races just before this increment it marks
      // the entry retired and may disconnect it, and the checks below reject it. If closeAll races
      // after the increment it sees an outstanding lease and defers the disconnect until this
      // caller finishes.
      live.leases++;
      if (live.retired ||
          _lifecycleGeneration != expectedGeneration ||
          !_isAlive(live.client)) {
        if (identical(_sessions[key], live)) _sessions.remove(key);
        _retire(live);
        _release(live);
        throw StateError('SSH session pool was reset while acquiring a session');
      }
      return SshLease<C>._(live.client, () => _release(live));
    });
  }

  /// Retire the cached client for [creds].
  ///
  /// Existing channels retain a lease and may finish; the underlying connection is disconnected only
  /// after the final lease closes. Supplying [suspect] prevents a late failure from evicting a newer
  /// replacement connection — otherwise a slow error from a dead session would kill the healthy one
  /// that already replaced it.
  void evict(SshCredentials creds, [C? suspect]) {
    final key = poolKey(creds);
    final entry = _sessions[key];
    if (entry == null) return;
    if (suspect != null && !identical(entry.client, suspect)) return;
    _sessions.remove(key);
    _retire(entry);
  }

  /// Disconnect and forget every pooled client.
  void closeAll() {
    final resetGeneration = ++_lifecycleGeneration;
    // Never clear() the map: an acquire that starts after the generation bump may legitimately
    // publish a post-reset entry while this method is scanning. Removing only entries from an older
    // generation guarantees every removed client is retired. An acquire that started before the
    // bump but publishes late fails its generation recheck and retires its own entry.
    for (final key in _sessions.keys.toList()) {
      final entry = _sessions[key];
      if (entry == null) continue;
      if (entryPredatesReset(entry.generation, resetGeneration)) {
        _sessions.remove(key);
        _retire(entry);
      }
    }
    // Do not drop the per-key locks: a waiter may still hold a reference to one. Replacing it here
    // would let a concurrent post-reset caller use a second lock for the same key.
  }

  /// Live entries, for tests and diagnostics.
  int get size => _sessions.length;

  void _release(_Entry<C> entry) {
    entry.leases--;
    if (entry.leases < 0) {
      throw StateError('SSH session lease released more than once');
    }
    if (entry.leases == 0 && entry.retired) _disconnect(entry.client);
  }

  void _retire(_Entry<C> entry) {
    entry.retired = true;
    if (entry.leases == 0) _disconnect(entry.client);
  }
}

class _Entry<C> {
  _Entry(this.client, this.generation);

  final C client;
  final int generation;

  /// Plain fields, not atomics: every read-modify-write below is synchronous, so on a
  /// single-threaded isolate it cannot interleave. The `await` in `acquire` is guarded by the
  /// per-key [AsyncLock] instead.
  int leases = 0;
  bool retired = false;
}

/// A borrowed connection. Closing is idempotent and must happen exactly once per acquire.
class SshLease<C> {
  SshLease._(this.client, this._releaseAction);

  /// A lease over a connection the pool does not own — used for jump-host connections, which cannot
  /// be pooled because the pool has nowhere to hold the paired bastion. Closing it tears the
  /// connection down outright rather than returning it to the pool.
  SshLease.unpooled(this.client, this._releaseAction);

  final C client;
  final void Function() _releaseAction;
  bool _released = false;

  void close() {
    if (_released) return;
    _released = true;
    _releaseAction();
  }
}

bool entryPredatesReset(int entryGeneration, int resetGeneration) =>
    entryGeneration < resetGeneration;
