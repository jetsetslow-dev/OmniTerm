import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/ssh_session_pool.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

/// A stand-in for an SSHClient, so the pool's lifecycle logic is testable without a socket.
class FakeClient {
  FakeClient(this.id);

  final int id;
  bool closed = false;
  bool alive = true;

  @override
  String toString() => 'FakeClient($id)';
}

void main() {
  const creds = SshCredentials(host: 'nas', port: 22, username: 'root', password: 'pw');

  late int nextId;
  late List<FakeClient> created;
  late int connectCalls;
  late Completer<void>? gate;

  SshSessionPool<FakeClient> makePool() => SshSessionPool<FakeClient>(
        connect: (_) async {
          connectCalls++;
          if (gate != null) await gate!.future;
          final client = FakeClient(nextId++);
          created.add(client);
          return client;
        },
        isAlive: (c) => c.alive && !c.closed,
        disconnect: (c) => c.closed = true,
      );

  setUp(() {
    nextId = 1;
    created = [];
    connectCalls = 0;
    gate = null;
  });

  group('reuse', () {
    test('a second acquire reuses the same connection', () async {
      final pool = makePool();
      final a = await pool.acquire(creds);
      a.close();
      final b = await pool.acquire(creds);
      b.close();

      expect(connectCalls, 1, reason: 're-authenticating every poll cycle is the thing to avoid');
      expect(identical(a.client, b.client), isTrue);
    });

    test('two concurrent acquires for the same host open only one connection', () async {
      // Without the per-key lock both callers would see an empty pool and each dial out.
      final pool = makePool();
      gate = Completer<void>();
      final futures = Future.wait([pool.acquire(creds), pool.acquire(creds)]);
      gate!.complete();
      final leases = await futures;

      expect(connectCalls, 1);
      expect(identical(leases[0].client, leases[1].client), isTrue);
      for (final l in leases) {
        l.close();
      }
    });

    test('a dead connection is transparently rebuilt', () async {
      final pool = makePool();
      final first = await pool.acquire(creds);
      first.close();
      (first.client).alive = false;

      final second = await pool.acquire(creds);
      second.close();

      expect(connectCalls, 2);
      expect(identical(first.client, second.client), isFalse);
    });
  });

  group('pool key', () {
    test('different credentials for the same endpoint do not share a connection', () async {
      // The bug this guards: keying only on user@host:port means editing a host's password keeps
      // reusing the session authenticated with the OLD password.
      final pool = makePool();
      const withOldPassword = SshCredentials(
          host: 'nas', port: 22, username: 'root', password: 'old');
      const withNewPassword = SshCredentials(
          host: 'nas', port: 22, username: 'root', password: 'new');

      (await pool.acquire(withOldPassword)).close();
      (await pool.acquire(withNewPassword)).close();

      expect(connectCalls, 2);
    });

    test('switching from password to key auth does not reuse the connection', () async {
      final pool = makePool();
      const byPassword =
          SshCredentials(host: 'nas', port: 22, username: 'root', password: 'pw');
      const byKey =
          SshCredentials(host: 'nas', port: 22, username: 'root', privateKeyPem: 'KEY');

      (await pool.acquire(byPassword)).close();
      (await pool.acquire(byKey)).close();

      expect(connectCalls, 2);
    });

    test('the key holds no plaintext secret', () {
      const c = SshCredentials(
        host: 'nas',
        port: 22,
        username: 'root',
        password: 'hunter2',
        privateKeyPem: 'PRIVATE-KEY-MATERIAL',
        passphrase: 'passphrase-secret',
        proxyPassword: 'proxy-secret',
      );
      final key = SshSessionPool.poolKey(c);
      expect(key, isNot(contains('hunter2')));
      expect(key, isNot(contains('PRIVATE-KEY-MATERIAL')));
      expect(key, isNot(contains('passphrase-secret')));
      expect(key, isNot(contains('proxy-secret')));
      expect(key, contains('root@nas:22'));
    });

    test('proxy, keepalive and compression all participate in the key', () {
      const base = SshCredentials(host: 'nas', port: 22, username: 'root');
      String k(SshCredentials c) => SshSessionPool.poolKey(c);
      expect(k(base), isNot(k(const SshCredentials(
          host: 'nas', port: 22, username: 'root', keepAliveSeconds: 60))));
      expect(k(base), isNot(k(const SshCredentials(
          host: 'nas', port: 22, username: 'root', compression: true))));
      expect(k(base), isNot(k(const SshCredentials(
          host: 'nas', port: 22, username: 'root', proxyType: 'socks5', proxyHost: 'p'))));
    });

    test('identical credentials produce a stable key', () {
      const a = SshCredentials(host: 'nas', port: 22, username: 'root', password: 'pw');
      const b = SshCredentials(host: 'nas', port: 22, username: 'root', password: 'pw');
      expect(SshSessionPool.poolKey(a), SshSessionPool.poolKey(b));
    });
  });

  group('leases defer teardown', () {
    test('evict does not disconnect while a lease is outstanding', () async {
      final pool = makePool();
      final lease = await pool.acquire(creds);

      pool.evict(creds);
      expect(lease.client.closed, isFalse,
          reason: 'an in-flight command must be allowed to finish');

      lease.close();
      expect(lease.client.closed, isTrue, reason: 'the last lease closing tears it down');
    });

    test('an evicted connection is not handed out again', () async {
      final pool = makePool();
      final first = await pool.acquire(creds);
      pool.evict(creds);

      final second = await pool.acquire(creds);
      expect(identical(first.client, second.client), isFalse);
      first.close();
      second.close();
    });

    test('a suspect eviction does not kill a newer replacement', () async {
      // A slow failure from a dead connection must not evict the healthy one that replaced it.
      final pool = makePool();
      final stale = await pool.acquire(creds);
      stale.close();
      stale.client.alive = false;

      final fresh = await pool.acquire(creds);
      pool.evict(creds, stale.client); // late failure referring to the old connection

      expect(fresh.client.closed, isFalse);
      expect(pool.size, 1, reason: 'the replacement must stay pooled');
      fresh.close();
    });

    test('closing a lease twice is a no-op, not an underflow', () async {
      final pool = makePool();
      final lease = await pool.acquire(creds)..close();
      expect(lease.close, returnsNormally);
    });

    test('concurrent leases each keep the connection alive', () async {
      final pool = makePool();
      final a = await pool.acquire(creds);
      final b = await pool.acquire(creds);
      pool.evict(creds);

      a.close();
      expect(b.client.closed, isFalse, reason: 'one lease remains');
      b.close();
      expect(b.client.closed, isTrue);
    });
  });

  group('closeAll', () {
    test('disconnects and forgets every idle connection', () async {
      final pool = makePool();
      (await pool.acquire(creds)).close();
      (await pool.acquire(const SshCredentials(host: 'box', port: 22, username: 'u'))).close();
      expect(pool.size, 2);

      pool.closeAll();

      expect(pool.size, 0);
      expect(created.every((c) => c.closed), isTrue);
    });

    test('defers teardown of a connection still under lease', () async {
      final pool = makePool();
      final lease = await pool.acquire(creds);

      pool.closeAll();
      expect(lease.client.closed, isFalse);

      lease.close();
      expect(lease.client.closed, isTrue);
    });

    test('a connection opened after the reset is kept', () async {
      final pool = makePool();
      pool.closeAll();
      final lease = await pool.acquire(creds);
      lease.close();

      expect(lease.client.closed, isFalse);
      expect(pool.size, 1, reason: 'closeAll must not poison the pool for later callers');
    });

    test('an acquire in flight across a reset is rejected rather than handing back a dead one', () async {
      final pool = makePool();
      gate = Completer<void>();
      final pending = pool.acquire(creds);
      // The reset lands while the connect is still awaiting.
      pool.closeAll();
      gate!.complete();

      await expectLater(pending, throwsA(isA<StateError>()));
      expect(created.single.closed, isTrue, reason: 'the orphaned connection must be torn down');
    });
  });

  test('entryPredatesReset compares generations', () {
    expect(entryPredatesReset(0, 1), isTrue);
    expect(entryPredatesReset(1, 1), isFalse);
    expect(entryPredatesReset(2, 1), isFalse);
  });
}
