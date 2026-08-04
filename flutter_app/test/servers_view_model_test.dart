import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/measurement_units.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/servers_view_model.dart';

class FakeSecureStorage extends FlutterSecureStorage {
  const FakeSecureStorage(this._values);
  final Map<String, String> _values;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late ServersViewModel vm;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // A mutable map: the store writes its generated key back on first use.
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    vm = ServersViewModel(app);
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await db.close();
  });

  Server server({required String name, String host = '10.0.0.1', String? group}) => Server(
    id: 0,
    name: name,
    host: host,
    port: 22,
    username: 'root',
    groupName: group,
    serverColor: 'Default',
    authType: 'password',
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
    healthScore: 100,
    lastLatency: 0,
    status: 'offline',
    authStatus: 'unknown',
  );

  /// Waits for the servers stream to deliver, since AppState observes it asynchronously.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('AppState selection', () {
    test('selectedServer falls back to the first host before anything is chosen', () async {
      await repo.insertServer(server(name: 'alpha'));
      await repo.insertServer(server(name: 'beta'));
      await app.start();
      await settle();

      expect(app.servers, hasLength(2));
      expect(app.selectedServer?.name, 'alpha');
    });

    test('a concrete host is bound as soon as the list loads', () async {
      // Without this, per-tab loaders whose guard compares server.id != selectedServerId bail out
      // and leave their spinner stuck until a host is picked by hand.
      await repo.insertServer(server(name: 'alpha'));
      await app.start();
      await settle();

      expect(app.selectedServerId, isNotNull);
    });

    test('an explicit selection wins over the fallback', () async {
      await repo.insertServer(server(name: 'alpha'));
      final betaId = await repo.insertServer(server(name: 'beta'));
      await app.start();
      await settle();

      app.selectedServerId = betaId;
      expect(app.selectedServer?.name, 'beta');
    });

    test('selecting an id that no longer exists yields null, not the wrong host', () async {
      await repo.insertServer(server(name: 'alpha'));
      await app.start();
      await settle();

      app.selectedServerId = 9999;
      expect(
        app.selectedServer,
        isNull,
        reason: 'silently substituting another host would act on the wrong machine',
      );
    });

    test('changing the selection notifies host-scoped draft owners', () async {
      var cleared = 0;
      app.onSelectedServerChanged.add(() => cleared++);

      app.selectedServerId = 1;
      expect(cleared, 1);
      app.selectedServerId = 1;
      expect(cleared, 1, reason: 're-selecting the same host must not discard a draft');
      app.selectedServerId = 2;
      expect(cleared, 2);
    });

    test('an empty fleet has no selected server', () async {
      await app.start();
      await settle();
      expect(app.selectedServer, isNull);
    });
  });

  group('AppState settings', () {
    test('defaults apply when nothing is stored', () async {
      await app.start();
      expect(app.metricsRetentionDays, 7);
      expect(app.measurementSystem, MeasurementSystem.metric);
      expect(app.alertsEnabled, isTrue, reason: 'alerts are on unless explicitly disabled');
      expect(app.homelabPresetsEnabled, isFalse);
    });

    test('stored settings are loaded and round-trip through save', () async {
      await app.start();
      await app.saveSetting('metrics_retention_days', '30');
      await app.saveSetting('measurement_system', 'imperial');
      await app.saveSetting('alerts_enabled', 'false');

      expect(app.metricsRetentionDays, 30);
      expect(app.measurementSystem, MeasurementSystem.imperial);
      expect(app.alertsEnabled, isFalse);
    });

    test('a malformed numeric setting falls back to its default', () async {
      await app.saveSetting('metrics_retention_days', 'not-a-number');
      await app.start();
      expect(
        app.metricsRetentionDays,
        7,
        reason: 'a corrupt row must not leave retention at zero and delete all history',
      );
    });

    test('the app pin is stored encrypted but read back in the clear', () async {
      await app.start();
      await app.saveSetting('app_pin', '1234');

      final raw = await db.appDataDao.getSetting('app_pin');
      expect(raw!.value, startsWith(SecretStore.prefix));
      expect(await repo.getSetting('app_pin'), '1234');
    });
  });

  group('filtering', () {
    setUp(() async {
      await repo.insertServer(server(name: 'web-prod', host: '10.0.0.1', group: 'prod'));
      await repo.insertServer(server(name: 'db-prod', host: '10.0.0.2', group: 'prod'));
      await repo.insertServer(server(name: 'nas', host: '192.168.1.50', group: 'home'));
      await app.start();
      await settle();
    });

    test('no filters shows every host', () {
      expect(vm.filteredServers, hasLength(3));
    });

    test('search matches the name case-insensitively', () {
      vm.serverSearchText = 'PROD';
      expect(vm.filteredServers.map((s) => s.name).toSet(), {'web-prod', 'db-prod'});
    });

    test('search also matches the address', () {
      // A user who remembers the IP but not the label still finds the machine.
      vm.serverSearchText = '192.168';
      expect(vm.filteredServers.map((s) => s.name), ['nas']);
    });

    test('the group chip narrows the list', () {
      vm.selectedGroupChip = 'home';
      expect(vm.filteredServers.map((s) => s.name), ['nas']);
    });

    test('search and group compose', () {
      vm.selectedGroupChip = 'prod';
      vm.serverSearchText = 'web';
      expect(vm.filteredServers.map((s) => s.name), ['web-prod']);
    });

    test('"All" disables the group filter', () {
      vm.selectedGroupChip = 'All';
      expect(vm.filteredServers, hasLength(3));
    });

    test('group chips are derived from the live list, with All first', () {
      expect(vm.groupChips.first, 'All');
      expect(vm.groupChips.toSet(), {'All', 'prod', 'home'});
    });

    test('a search matching nothing yields an empty list, not everything', () {
      vm.serverSearchText = 'zzzz';
      expect(vm.filteredServers, isEmpty);
    });
  });

  group('multi-select', () {
    setUp(() async {
      await repo.insertServer(server(name: 'a'));
      await repo.insertServer(server(name: 'b'));
      await app.start();
      await settle();
    });

    test('toggling adds and removes', () {
      final id = vm.servers.first.id;
      vm.toggleBulkSelection(id);
      expect(vm.selectedServerIdsForBulk, [id]);
      vm.toggleBulkSelection(id);
      expect(vm.selectedServerIdsForBulk, isEmpty);
    });

    test('leaving multi-select clears the selection', () {
      vm.isMultiSelectMode = true;
      vm.toggleBulkSelection(vm.servers.first.id);
      vm.isMultiSelectMode = false;
      expect(
        vm.selectedServerIdsForBulk,
        isEmpty,
        reason: 'a stale tick would let a later bulk action hit a host the user cannot see',
      );
    });

    test('bulk delete removes every selected host and exits the mode', () async {
      vm.isMultiSelectMode = true;
      for (final s in vm.servers) {
        vm.toggleBulkSelection(s.id);
      }
      await vm.deleteSelectedServers();
      await settle();

      expect(await repo.getAllServers(), isEmpty);
      expect(vm.isMultiSelectMode, isFalse);
      expect(vm.selectedServerIdsForBulk, isEmpty);
    });

    test('bulk group assignment applies to the selection only', () async {
      final first = vm.servers.first;
      vm.toggleBulkSelection(first.id);
      await vm.setGroupForSelected('newgroup');
      await settle();

      final saved = await repo.getAllServers();
      expect(saved.firstWhere((s) => s.id == first.id).groupName, 'newgroup');
      expect(saved.where((s) => s.id != first.id).every((s) => s.groupName != 'newgroup'), isTrue);
    });
  });

  group('deletion', () {
    test('deleting the selected host clears the selection', () async {
      final id = await repo.insertServer(server(name: 'doomed'));
      await app.start();
      await settle();
      app.selectedServerId = id;

      await vm.deleteServer(id);
      await settle();

      expect(
        app.selectedServerId,
        isNull,
        reason: 'screens must not keep operating against an id that no longer resolves',
      );
    });
  });

  group('host limit', () {
    test('applies only to a locked Play Store build', () async {
      await repo.insertServer(server(name: 'only'));
      await app.start();
      await settle();

      expect(vm.hostLimitReached(playStoreBuild: true, unlocked: false), isTrue);
      expect(vm.hostLimitReached(playStoreBuild: true, unlocked: true), isFalse);
      expect(
        vm.hostLimitReached(playStoreBuild: false, unlocked: false),
        isFalse,
        reason: 'the source-available build has no limit',
      );
    });

    test('an empty fleet is under the limit', () async {
      await app.start();
      await settle();
      expect(vm.hostLimitReached(playStoreBuild: true, unlocked: false), isFalse);
    });
  });
}
