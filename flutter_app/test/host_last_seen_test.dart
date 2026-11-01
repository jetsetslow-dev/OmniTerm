import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';

import 'support/fake_secure_storage.dart';

/// The "Last seen" time an offline host's card shows, as Kotlin's `lastSeenAt`.
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<int> addHost(String name) => db.serverDao.insertServer(
    ServersCompanion.insert(name: name, host: '10.0.0.1', username: 'root'),
  );

  Future<void> addMetric(int serverId, int timestamp) => repo.insertMetric(
    MetricHistoryCompanion.insert(
      serverId: serverId,
      timestamp: timestamp,
      cpuUsage: 0,
      ramUsage: 0,
      diskUsage: 0,
      latency: 0,
      networkIn: 0,
      networkOut: 0,
    ),
  );

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('starts from the newest stored sample, so it survives a restart', () async {
    final id = await addHost('nas');
    await addMetric(id, 1000);
    await addMetric(id, 5000);

    await app.start();
    await settle();

    expect(app.lastSeenAt(id), 5000);
  });

  test('a host never heard from has no time', () async {
    final id = await addHost('nas');
    await app.start();
    await settle();

    expect(app.lastSeenAt(id), isNull);
  });

  test('an older report never replaces a newer one', () async {
    final id = await addHost('nas');
    await app.start();
    app
      ..noteSeen(id, 9000)
      ..noteSeen(id, 4000);

    expect(app.lastSeenAt(id), 9000);
  });

  test('a host moved to another address is forgotten, since it may be another machine', () async {
    final id = await addHost('nas');
    await app.start();
    await settle();
    app.noteSeen(id, 9000);

    await repo.updateServer((await repo.getServerById(id))!.copyWith(host: '10.0.0.2'));
    await settle();

    expect(app.lastSeenAt(id), isNull);
  });
}
