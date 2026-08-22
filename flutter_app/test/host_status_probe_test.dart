import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';

import 'support/fake_secure_storage.dart';

class _FakeProbe implements NetworkProbe {
  _FakeProbe({this.reachable = const {}, this.throwFor = const {}});

  final Set<String> reachable;
  final Set<String> throwFor;
  final List<String> probed = [];
  int inFlight = 0;
  int peak = 0;

  @override
  Future<Duration?> tcpPing(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final key = '$host:$port';
    probed.add(key);
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    inFlight--;
    if (throwFor.contains(key)) throw StateError('network down');
    return reachable.contains(key) ? const Duration(milliseconds: 7) : null;
  }

  @override
  Future<void> sendMagicPacket(Uint8List packet, String broadcast, int port) async {}

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeSshTransport implements SshTransport {
  _FakeSshTransport({this.failure});

  final String? failure;
  final List<SshCredentials> tested = [];

  @override
  Future<String?> testConnection(SshCredentials creds) async {
    tested.add(creds);
    return failure;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _CompletingSshTransport implements SshTransport {
  final Completer<void> started = Completer<void>();
  final Completer<String?> result = Completer<String?>();

  @override
  Future<String?> testConnection(SshCredentials creds) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
  });

  tearDown(() => db.close());

  Server server({
    required String name,
    String host = '10.0.0.5',
    int port = 22,
    String status = 'unknown',
    int healthScore = 82,
    String proxyType = 'none',
  }) => Server(
    id: 0,
    name: name,
    host: host,
    port: port,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    authPassword: 'pw',
    sudoPassword: '',
    notes: '',
    keepAlive: 30,
    sshCompression: false,
    persistentSession: false,
    proxyCommand: '',
    proxyType: proxyType,
    proxyHost: '',
    proxyPort: 0,
    proxyUser: '',
    proxyPassword: '',
    agentForwarding: false,
    healthScore: healthScore,
    lastLatency: 0,
    status: status,
    authStatus: 'ok',
  );

  Future<Server> only() async => (await repo.getAllServers()).single;

  test('a reachable host becomes online, with its latency', () async {
    // This column is what Monitor, Infra, Fleet, SFTP and the terminal all filter on. Nothing else
    // in the app writes it.
    await repo.insertServer(server(name: 'nas'));
    final probe = HostStatusProbe(repo, probe: _FakeProbe(reachable: {'10.0.0.5:22'}));

    await probe.sweep();

    final row = await only();
    expect(row.status, 'online');
    expect(row.lastLatency, 7);
    probe.dispose();
  });

  test('an unreachable host becomes offline', () async {
    await repo.insertServer(server(name: 'nas', status: 'online'));
    final probe = HostStatusProbe(repo, probe: _FakeProbe());

    await probe.sweep();

    expect((await only()).status, 'offline');
    probe.dispose();
  });

  test('a failed TCP probe falls back to the configured SSH connection', () async {
    await repo.insertServer(server(name: 'nas', status: 'online'));
    final ssh = _FakeSshTransport();
    final probe = HostStatusProbe(repo, probe: _FakeProbe(), transport: ssh);

    await probe.sweep();

    expect((await only()).status, 'online');
    expect(ssh.tested.single.endpointKey, 'root@10.0.0.5:22');
    probe.dispose();
  });

  test('a proxied host skips the invalid direct TCP route', () async {
    await repo.insertServer(server(name: 'nas', proxyType: 'ssh'));
    final network = _FakeProbe();
    final ssh = _FakeSshTransport();
    final probe = HostStatusProbe(repo, probe: network, transport: ssh);

    await probe.sweep();

    expect(network.probed, isEmpty);
    expect(ssh.tested, hasLength(1));
    expect((await only()).status, 'online');
    probe.dispose();
  });

  test('an authentication failure proves the SSH endpoint is online', () async {
    await repo.insertServer(server(name: 'nas'));
    final probe = HostStatusProbe(
      repo,
      probe: _FakeProbe(),
      transport: _FakeSshTransport(failure: 'SSHAuthFailError'),
    );

    await probe.sweep();

    final row = await only();
    expect(row.status, 'online');
    expect(row.authStatus, 'failed');
    probe.dispose();
  });

  test('a definitive SSH timeout marks the endpoint offline', () async {
    await repo.insertServer(server(name: 'nas', status: 'online'));
    final probe = HostStatusProbe(
      repo,
      probe: _FakeProbe(),
      transport: _FakeSshTransport(failure: 'Connection timed out'),
    );

    await probe.sweep();

    expect((await only()).status, 'offline');
    probe.dispose();
  });

  test('a live terminal always keeps its host online', () async {
    await repo.insertServer(server(name: 'nas', status: 'offline'));
    final ssh = _FakeSshTransport(failure: 'Connection timed out');
    final probe = HostStatusProbe(repo, probe: _FakeProbe(), transport: ssh);
    final row = await only();
    probe.setLiveSessionServers({row.id});

    await probe.sweep();

    expect((await only()).status, 'online');
    expect(ssh.tested, isEmpty, reason: 'an open terminal already proves reachability');
    probe.dispose();
  });

  test('an in-flight probe cannot overwrite a later successful shell', () async {
    await repo.insertServer(server(name: 'nas', status: 'online'));
    final ssh = _CompletingSshTransport();
    final probe = HostStatusProbe(repo, probe: _FakeProbe(), transport: ssh);
    final sweep = probe.sweep();
    await ssh.started.future;

    final row = await only();
    probe.setLiveSessionServers({row.id});
    await probe.markReachable(row);
    ssh.result.complete('Connection timed out');
    await sweep;

    final saved = await only();
    expect(saved.status, 'online');
    expect(saved.authStatus, 'ok');
    probe.dispose();
  });

  test('closing the last live terminal immediately rechecks the host', () async {
    await repo.insertServer(server(name: 'nas', status: 'online'));
    final ssh = _CompletingSshTransport();
    final probe = HostStatusProbe(repo, probe: _FakeProbe(), transport: ssh);
    final row = await only();
    probe.setLiveSessionServers({row.id});

    probe.setLiveSessionServers(const <int>{});
    await ssh.started.future;
    ssh.result.complete('Connection timed out');
    // Joins the close-triggered check rather than starting a competing handshake.
    await probe.probeOne(row);

    expect((await only()).status, 'offline');
    probe.dispose();
  });

  test('a probe that throws still lands on offline, never stuck mid-flight', () async {
    // A host stuck at "connecting" forever is worse than one honestly marked offline.
    await repo.insertServer(server(name: 'nas', status: 'offline'));
    final probe = HostStatusProbe(repo, probe: _FakeProbe(throwFor: {'10.0.0.5:22'}));

    await probe.sweep();

    expect((await only()).status, 'offline');
    probe.dispose();
  });

  test('the health score survives a probe', () async {
    // Health is Monitor's, computed from real telemetry; overwriting it from a ping would make a
    // reachable-but-struggling host look perfect.
    await repo.insertServer(server(name: 'nas', healthScore: 42));
    final probe = HostStatusProbe(repo, probe: _FakeProbe(reachable: {'10.0.0.5:22'}));

    await probe.sweep();

    expect((await only()).healthScore, 42);
    probe.dispose();
  });

  test('a retried offline host is shown as connecting first', () async {
    // So a slow probe reads as work in progress rather than a host that is simply still down.
    await repo.insertServer(server(name: 'nas', status: 'offline'));
    final states = <String>[];
    final sub = repo.serversStream.listen((rows) {
      if (rows.isNotEmpty) states.add(rows.single.status);
    });
    final probe = HostStatusProbe(repo, probe: _FakeProbe(reachable: {'10.0.0.5:22'}));

    await probe.sweep();
    await Future<void>.delayed(Duration.zero);

    expect(states, contains('connecting'));
    expect((await only()).status, 'online');
    await sub.cancel();
    probe.dispose();
  });

  test('the sweep is bounded', () async {
    // An unbounded sweep opens one socket per host at once, which on a phone exhausts descriptors
    // and battery on a fleet of any size.
    for (var i = 0; i < 25; i++) {
      await repo.insertServer(server(name: 'h$i', host: '10.0.0.$i'));
    }
    final fake = _FakeProbe();
    final probe = HostStatusProbe(repo, probe: fake);

    await probe.sweep();

    expect(fake.probed, hasLength(25));
    expect(fake.peak, lessThanOrEqualTo(HostStatusProbe.maxConcurrent));
    probe.dispose();
  });

  test('sweeps do not overlap', () async {
    // Two in flight would double the socket count and race each other's writes.
    for (var i = 0; i < 10; i++) {
      await repo.insertServer(server(name: 'h$i', host: '10.0.0.$i'));
    }
    final fake = _FakeProbe();
    final probe = HostStatusProbe(repo, probe: fake);

    final first = probe.sweep();
    await probe.sweep(); // returns immediately, does nothing
    await first;

    expect(fake.probed, hasLength(10));
    probe.dispose();
  });

  test('with no hosts it does nothing at all', () async {
    final fake = _FakeProbe();
    final probe = HostStatusProbe(repo, probe: fake);

    await probe.sweep();

    expect(fake.probed, isEmpty);
    probe.dispose();
  });

  test('a disposed probe stops touching the database', () async {
    // It outlives nothing: once disposed it must not keep writing statuses under a closed screen.
    await repo.insertServer(server(name: 'nas'));
    final fake = _FakeProbe();
    final probe = HostStatusProbe(repo, probe: fake, interval: const Duration(hours: 1));

    probe.dispose();
    await probe.sweep();

    expect(fake.probed, isEmpty);
  });

  /// "Has anything actually looked at this host?", ported from Kotlin's `probedServerIds`
  /// (`ui/AppViewModel.kt:4496`).
  ///
  /// A host's stored status is `offline` from the moment it is created, so status alone cannot tell
  /// "we checked, and it is down" from "nobody has checked yet".
  group('probed tracking', () {
    test('a host nothing has looked at is not marked probed', () async {
      final probe = HostStatusProbe(repo, probe: _FakeProbe());
      expect(probe.hasProbed(1), isFalse);
      probe.dispose();
    });

    test('a reachable host is marked probed', () async {
      await repo.insertServer(server(name: 'box', host: '10.0.0.5'));
      final probe = HostStatusProbe(repo, probe: _FakeProbe(reachable: {'10.0.0.5:22'}));

      await probe.probeOne((await repo.getAllServers()).single);

      expect(probe.hasProbed(1), isTrue);
      probe.dispose();
    });

    test('an unreachable host is marked probed too', () async {
      // This is the case the warning exists for: a real answer of "no".
      await repo.insertServer(server(name: 'box', host: '10.0.0.5'));
      final probe = HostStatusProbe(repo, probe: _FakeProbe());

      await probe.probeOne((await repo.getAllServers()).single);

      expect(probe.hasProbed(1), isTrue);
      probe.dispose();
    });

    test('a probe that threw does not count', () async {
      // A failed probe says nothing about the host, so it must not arm a warning about it.
      await repo.insertServer(server(name: 'box', host: '10.0.0.5'));
      final probe = HostStatusProbe(repo, probe: _FakeProbe(throwFor: {'10.0.0.5:22'}));

      await probe.probeOne((await repo.getAllServers()).single);

      expect(probe.hasProbed(1), isFalse);
      probe.dispose();
    });
  });

  /// The warning rule itself.
  group('shouldWarnHostOffline', () {
    test('never warns about a host nothing has probed', () {
      // The regression: a freshly added host is stored as `offline`, so warning on status alone
      // fired the first time the user connected to a host they had just created.
      expect(shouldWarnHostOffline(probed: false, status: 'offline'), isFalse);
      expect(shouldWarnHostOffline(probed: false, status: 'connecting'), isFalse);
    });

    test('warns about a probed host that is not online', () {
      expect(shouldWarnHostOffline(probed: true, status: 'offline'), isTrue);
    });

    test('never warns about a host that is online', () {
      expect(shouldWarnHostOffline(probed: true, status: 'online'), isFalse);
    });
  });
}
