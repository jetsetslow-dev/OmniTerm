import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/platform/secret_store.dart';
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
    proxyType: 'none',
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
}
