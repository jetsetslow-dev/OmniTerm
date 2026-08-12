import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/backup/backup_envelope.dart';
import 'package:omniterm/data/backup/backup_payload.dart';
import 'package:omniterm/data/script_presets.dart';
import 'package:omniterm/domain/backup_selection.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';
import 'package:omniterm/ui/view_model/scripts_view_model.dart';

import 'support/fake_secure_storage.dart';

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

  Server server({required String name, String host = '10.0.0.1', String? password = 'hunter2'}) =>
      Server(
        id: 0,
        name: name,
        host: host,
        port: 2222,
        username: 'root',
        serverColor: 'Default',
        authType: 'password',
        authPassword: password,
        sudoPassword: 'sudo-secret',
        notes: 'a note',
        keepAlive: 45,
        sshCompression: true,
        persistentSession: false,
        proxyCommand: '',
        proxyType: 'none',
        proxyHost: '',
        proxyPort: 0,
        proxyUser: '',
        proxyPassword: '',
        agentForwarding: false,
        healthScore: 77,
        lastLatency: 12,
        status: 'online',
        authStatus: 'ok',
      );

  CredentialProfile profile(String name, {String password = 'profile-secret'}) => CredentialProfile(
    id: 0,
    profileName: name,
    username: 'deploy',
    authType: 'password',
    password: password,
    groupName: 'General',
  );

  Future<BackupViewModel> boot() async {
    await app.start();
    await Future<void>.delayed(Duration.zero);
    return BackupViewModel(app);
  }

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// A fresh device to restore onto.
  Future<(AppDatabase, AppRepository, AppState, BackupViewModel)> freshDevice() async {
    final freshDb = AppDatabase(NativeDatabase.memory());
    final freshRepo = AppRepository(
      freshDb,
      SecretStore(storage: FakeSecureStorage(<String, String>{})),
    );
    final freshApp = AppState(freshRepo);
    await freshApp.start();
    return (freshDb, freshRepo, freshApp, BackupViewModel(freshApp));
  }

  /// Exports and returns the *payload*, decrypting when a passphrase was used.
  ///
  /// A passphrased export returns the envelope, not the document — decoding that directly would
  /// silently inspect the wrong object and every field would read as absent.
  Future<Map<String, dynamic>> exportedDocument(
    BackupViewModel vm, {
    String passphrase = 'a-long-enough-passphrase',
  }) async {
    final contents = await vm.exportBackup(passphrase);
    expect(contents, isNotNull, reason: vm.error ?? 'export returned null');
    final json = passphrase.isEmpty ? contents! : await decryptBackup(contents!, passphrase);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  group('export', () {
    test('carries the selected sections and omits the rest', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      vm
        ..selectNone()
        ..toggleSection(BackupSection.servers, enabled: true);

      final document = await exportedDocument(vm);
      expect(document['servers'], hasLength(1));
      expect(document.containsKey('sshKeys'), isFalse);
      expect(document.containsKey('settings'), isFalse);
      vm.dispose();
    });

    test('selecting alert rules pulls hosts in, so the rules can resolve', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      vm
        ..selectNone()
        ..toggleSection(BackupSection.alertRules, enabled: true);

      final document = await exportedDocument(vm);
      expect(document.containsKey('servers'), isTrue);
      expect(document.containsKey('alertRules'), isTrue);
      vm.dispose();
    });

    test('the app lock PIN never leaves the device', () async {
      // It is a credential for *this* device, not a preference; restoring it elsewhere would carry
      // a lock the user did not set there.
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertSetting('biometrics_enabled', 'true');
      await repo.insertSetting('pin_failed_attempts', '4');
      await repo.insertSetting('pin_locked_until', '999999');
      await repo.insertSetting('app_lock_grace_ms', '30000');
      await repo.insertSetting('theme', 'dark');
      final vm = await boot();

      final document = await exportedDocument(vm, passphrase: 'a-long-enough-passphrase');
      final keys = (document['settings'] as List).map((s) => (s as Map)['key'] as String).toList();
      expect(keys, contains('theme'));
      for (final localKey in const [
        'app_pin',
        'app_lock_enabled',
        'biometrics_enabled',
        'pin_failed_attempts',
        'pin_locked_until',
        'app_lock_grace_ms',
      ]) {
        expect(keys, isNot(contains(localKey)), reason: '$localKey must stay on this device');
      }
      vm.dispose();
    });

    test('a pristine preset is not exported, an edited one is', () async {
      // A fresh install re-seeds its own presets, so carrying them would duplicate defaults; an
      // edited one is the user's work and must survive.
      final scripts = ScriptsViewModel(app);
      await scripts.start();
      await scripts.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      final preset = scripts.allScripts.firstWhere((s) => s.presetKey == 'fleet.cpu');
      await scripts.saveScript(
        existing: preset,
        name: preset.name,
        command: 'my own command',
        availableForQuick: false,
        availableForFleet: true,
      );
      await settle();
      scripts.dispose();

      final vm = await boot();
      final document = await exportedDocument(vm, passphrase: 'a-long-enough-passphrase');
      final exported = (document['scripts'] as List).cast<Map<String, dynamic>>();

      expect(exported, hasLength(1));
      expect(exported.single['command'], 'my own command');
      // The key survives, so the toggle can still remove or reset it after a restore.
      expect(exported.single['presetKey'], 'fleet.cpu');
      vm.dispose();
    });

    test('an empty selection is refused rather than writing an empty file', () async {
      final vm = await boot();
      vm.selectNone();
      expect(await vm.exportBackup('a-long-enough-passphrase'), isNull);
      expect(vm.error, contains('at least one'));
      vm.dispose();
    });

    test('a sensitive selection demands a passphrase', () async {
      // Otherwise every stored password lands in a plain file the user may drop in a cloud drive.
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      expect(vm.requiresPassphrase, isTrue);
      expect(await vm.exportBackup(''), isNull);
      expect(vm.error, contains('needs a passphrase'));
      vm.dispose();
    });

    test('settings alone can be exported without one', () async {
      await repo.insertSetting('theme', 'dark');
      final vm = await boot();
      vm
        ..selectNone()
        ..toggleSection(BackupSection.settings, enabled: true);

      expect(vm.requiresPassphrase, isFalse);
      final contents = await vm.exportBackup('');
      expect(contents, isNotNull);
      expect(BackupViewModel.looksEncrypted(contents!), isFalse);
      vm.dispose();
    });

    test('the suggested file name is dated, so backups do not overwrite each other', () async {
      final vm = await boot();
      expect(vm.suggestedFileName(), matches(RegExp(r'^omniterm-\d{8}-\d{4}\.omnibak$')));
      vm.dispose();
    });
  });

  group('restore', () {
    test('brings hosts back with their secrets intact', () async {
      await repo.insertServer(server(name: 'nas', host: '10.0.0.9'));
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      // A different device: a fresh database with nothing in it.
      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo = AppRepository(
        freshDb,
        SecretStore(storage: FakeSecureStorage(<String, String>{})),
      );
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      final freshVm = BackupViewModel(freshApp);

      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restored = (await freshRepo.getAllServers()).single;
      expect(restored.name, 'nas');
      expect(restored.host, '10.0.0.9');
      expect(restored.authPassword, 'hunter2');
      expect(restored.sudoPassword, 'sudo-secret');
      expect(restored.port, 2222);

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('remaps credential profile ids for hosts and shares on an additive restore', () async {
      final sourceProfileId = await repo.insertProfile(profile('production'));
      expect(sourceProfileId, 1);
      await repo.insertServer(
        server(name: 'profile-host').copyWith(
          authType: 'profile',
          authPassword: const Value(null),
          authProfileId: Value(sourceProfileId),
        ),
      );
      await repo.insertNetworkShare(
        NetworkShare(
          id: 0,
          name: 'profile-share',
          protocol: 'SMB',
          address: '10.0.0.8',
          port: 445,
          sharePath: 'data',
          workgroup: '',
          username: '',
          password: '',
          authProfileId: sourceProfileId,
          anonymous: false,
          useHttps: false,
          notes: '',
          lastChecked: 0,
          lastStatus: '',
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      final unrelatedId = await freshRepo.insertProfile(
        profile('unrelated', password: 'do-not-use'),
      );
      expect(unrelatedId, sourceProfileId, reason: 'the collision is the regression condition');
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restoredProfile = (await freshRepo.getAllProfiles()).singleWhere(
        (p) => p.profileName == 'production',
      );
      expect(restoredProfile.id, isNot(unrelatedId));
      expect((await freshRepo.getAllServers()).single.authProfileId, restoredProfile.id);
      expect((await freshRepo.getAllNetworkShares()).single.authProfileId, restoredProfile.id);

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('a selective host restore carries only credentials used by the chosen host', () async {
      final firstProfile = await repo.insertProfile(profile('first'));
      final secondProfile = await repo.insertProfile(profile('second'));
      final firstHost = await repo.insertServer(
        server(name: 'first-host').copyWith(
          authType: 'profile',
          authPassword: const Value(null),
          authProfileId: Value(firstProfile),
        ),
      );
      await repo.insertServer(
        server(name: 'second-host', host: '10.0.0.2').copyWith(
          authType: 'profile',
          authPassword: const Value(null),
          authProfileId: Value(secondProfile),
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      await freshVm.importBackup(
        contents!,
        'a-long-enough-passphrase',
        selection: BackupSelection.all(),
        selectedServerIds: {firstHost},
      );

      expect((await freshRepo.getAllServers()).single.name, 'first-host');
      expect((await freshRepo.getAllProfiles()).single.profileName, 'first');

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test(
      'restoring hosts without profiles clears source profile ids instead of guessing',
      () async {
        final sourceProfileId = await repo.insertProfile(profile('source'));
        await repo.insertServer(
          server(name: 'profile-host').copyWith(
            authType: 'profile',
            authPassword: const Value(null),
            authProfileId: Value(sourceProfileId),
          ),
        );
        final vm = await boot();
        final contents = await vm.exportBackup('a-long-enough-passphrase');

        final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
        await freshRepo.insertProfile(profile('unrelated'));
        await freshVm.importBackup(
          contents!,
          'a-long-enough-passphrase',
          selection: const BackupSelection({BackupSection.servers}),
        );

        expect((await freshRepo.getAllProfiles()).single.profileName, 'unrelated');
        expect((await freshRepo.getAllServers()).single.authProfileId, isNull);

        freshVm.dispose();
        freshApp.dispose();
        await freshDb.close();
        vm.dispose();
      },
    );

    test('a restored host starts unprobed rather than carrying a stale score', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo = AppRepository(
        freshDb,
        SecretStore(storage: FakeSecureStorage(<String, String>{})),
      );
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      final freshVm = BackupViewModel(freshApp);
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restored = (await freshRepo.getAllServers()).single;
      expect(restored.status, 'offline');
      expect(
        restored.healthScore,
        100,
        reason: 'a health figure for a connection never made here would be a lie',
      );

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('host bookmarks follow the restored host id and last-open paths stay local', () async {
      final sourceHostId = await repo.insertServer(server(name: 'bookmarked'));
      await repo.insertSetting('sftp_bookmarks_$sourceHostId', '/srv/data\n/var/log');
      await repo.insertSetting('sftp_last_path_$sourceHostId', '/private/source/path');
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      final unrelatedHostId = await freshRepo.insertServer(
        server(name: 'already-here', host: '10.0.0.99'),
      );
      expect(unrelatedHostId, sourceHostId, reason: 'the collision is the regression condition');
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restoredHost = (await freshRepo.getAllServers()).singleWhere(
        (host) => host.name == 'bookmarked',
      );
      expect(
        await freshRepo.getSetting('sftp_bookmarks_${restoredHost.id}'),
        '/srv/data\n/var/log',
      );
      expect(await freshRepo.getSetting('sftp_bookmarks_$unrelatedHostId'), isNull);
      expect(await freshRepo.getSetting('sftp_last_path_${restoredHost.id}'), isNull);

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('is additive, so restoring the wrong file is recoverable', () async {
      // There is no undo for a restore; wiping first would make one mistake permanent.
      await repo.insertServer(server(name: 'existing'));
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');
      await vm.importBackup(contents!, 'a-long-enough-passphrase');
      await settle();

      final all = await repo.getAllServers();
      expect(all, hasLength(2));
      expect(all.map((s) => s.name), everyElement('existing'));
      vm.dispose();
    });

    test('an alert rule follows its host to the new id', () async {
      final serverId = await repo.insertServer(server(name: 'nas'));
      await repo.insertRule(
        AlertRulesCompanion.insert(
          serverId: serverId,
          metricName: 'CPU Usage',
          thresholdValue: 80,
          severity: 'WARNING',
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo = AppRepository(
        freshDb,
        SecretStore(storage: FakeSecureStorage(<String, String>{})),
      );
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      // Something already occupies id 1, so the restored host cannot keep its old id.
      await freshRepo.insertServer(server(name: 'unrelated'));
      final freshVm = BackupViewModel(freshApp);
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restoredHost = (await freshRepo.getAllServers()).firstWhere((s) => s.name == 'nas');
      final rule = (await freshRepo.getAllRules()).single;
      expect(
        rule.serverId,
        restoredHost.id,
        reason: 'the rule must watch the host it came with, not whichever id it used to have',
      );

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('a fleet-wide rule keeps its scope', () async {
      await repo.insertRule(
        AlertRulesCompanion.insert(
          serverId: 0,
          metricName: 'CPU Usage',
          thresholdValue: 80,
          severity: 'WARNING',
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo = AppRepository(
        freshDb,
        SecretStore(storage: FakeSecureStorage(<String, String>{})),
      );
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      final freshVm = BackupViewModel(freshApp);
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      expect(
        (await freshRepo.getAllRules()).single.serverId,
        0,
        reason: 'remapping it would narrow a rule watching every host to just one',
      );

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('a rule whose host is missing is skipped and reported', () async {
      // Restoring it against an arbitrary host would silently point it at the wrong machine.
      const orphan =
          '{"v":2,"alertRules":[{"serverId":99,"metricName":"CPU Usage",'
          '"thresholdValue":80,"severity":"WARNING"}]}';
      final vm = await boot();
      final counts = await vm.importBackup(orphan, '');

      expect(counts!['alertRulesSkipped'], 1);
      expect(await repo.getAllRules(), isEmpty);
      expect(vm.status, contains('skipped'));
      vm.dispose();
    });

    test('plain JSON is restored without demanding a passphrase', () async {
      final vm = await boot();
      const plain = '{"v":2,"wolTargets":[{"name":"nas","macAddress":"aa:bb:cc:dd:ee:ff"}]}';
      expect(BackupViewModel.looksEncrypted(plain), isFalse);

      await vm.importBackup(plain, '');
      expect((await repo.getAllWolTargets()).single.name, 'nas');
      vm.dispose();
    });

    test('an encrypted file is recognised as such', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');
      expect(BackupViewModel.looksEncrypted(contents!), isTrue);
      vm.dispose();
    });

    test('a wrong passphrase is reported as one', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      expect(await vm.importBackup(contents!, 'wrong'), isNull);
      expect(vm.error, contains('passphrase'));
      vm.dispose();
    });

    test('rubbish is reported rather than half-restored', () async {
      final vm = await boot();
      expect(await vm.importBackup('not a backup at all', ''), isNull);
      expect(vm.error, isNotNull);
      expect(await repo.getAllServers(), isEmpty);
      vm.dispose();
    });

    test('a failure in a later section rolls the whole database restore back', () async {
      final vm = await boot();
      final malformed = jsonEncode({
        'servers': [
          {'id': 7, 'name': 'must-not-remain', 'host': '10.0.0.7', 'port': 22, 'username': 'root'},
        ],
        'settings': [
          {
            'key': 'theme',
            'value': <String, Object?>{'not': 'a string'},
          },
        ],
      });

      expect(await vm.importBackup(malformed, ''), isNull);
      expect(await repo.getAllServers(), isEmpty);
      expect(await repo.getSetting('theme'), isNull);
      expect(vm.error, contains('Could not restore'));
      vm.dispose();
    });

    test('an unknown section in the file is ignored, not fatal', () async {
      // A backup from a newer build must not be unreadable by an older one.
      final vm = await boot();
      const withExtra =
          '{"v":99,"somethingNew":[{"a":1}],'
          '"wolTargets":[{"name":"nas","macAddress":"aa:bb:cc:dd:ee:ff"}]}';
      await vm.importBackup(withExtra, '');

      expect((await repo.getAllWolTargets()), hasLength(1));
      expect(vm.error, isNull);
      vm.dispose();
    });
  });

  test('the export omits pristine presets even when scripts are selected', () async {
    final scripts = ScriptsViewModel(app);
    await scripts.start();
    await scripts.setPresetsEnabled(fleet: false, enabled: true);
    await settle();
    scripts.dispose();

    final vm = await boot();
    final document = await exportedDocument(vm, passphrase: 'a-long-enough-passphrase');
    expect(
      document['scripts'],
      isEmpty,
      reason: 'a fresh install re-seeds these, so exporting them would duplicate defaults',
    );
    expect(kHomelabPresets, isNotEmpty, reason: 'the presets really were seeded');
    vm.dispose();
  });

  group('port forwards', () {
    Future<void> addTunnel({int serverId = 1, String name = 'web', bool autoStart = true}) =>
        repo.insertPortForward(
          PortForwardsCompanion.insert(
            serverId: serverId,
            name: name,
            kind: const Value('local'),
            bindHost: const Value('127.0.0.1'),
            bindPort: 8080,
            destHost: const Value('10.0.0.5'),
            destPort: const Value(80),
            autoStart: Value(autoStart),
          ),
        );

    test('tunnels are carried with the host they run over', () async {
      // Blocked until the Tunnels screen existed (§18); a backup that quietly omitted them was a
      // backup that could not restore a working setup.
      await repo.insertServer(server(name: 'nas'));
      await addTunnel();
      final vm = await boot();
      vm
        ..selectNone()
        ..toggleSection(BackupSection.portForwards, enabled: true);

      final document = await exportedDocument(vm);
      expect(document['portForwards'], hasLength(1));
      final row = (document['portForwards'] as List).single as Map<String, dynamic>;
      expect(row['name'], 'web');
      expect(row['bindPort'], 8080);
      // The host comes with it, because a tunnel without one has nothing to run over.
      expect(document['servers'], hasLength(1));
      vm.dispose();
    });

    test('a restored tunnel points at the restored host, not the old id', () async {
      await repo.insertServer(server(name: 'nas'));
      await addTunnel();
      final vm = await boot();
      vm
        ..selectNone()
        ..toggleSection(BackupSection.portForwards, enabled: true);
      // A passphrase is required here, not incidental: a tunnel carries a host's address and the
      // port it exposes, so the selection counts as sensitive and an unencrypted export is refused.
      final contents = await vm.exportBackup('a-long-enough-passphrase');
      await settle();

      final counts = await vm.importBackup(contents!, 'a-long-enough-passphrase');
      await settle();

      expect(counts!['portForwards'], 1);
      final servers = await repo.getAllServers();
      final tunnels = await repo.getAllPortForwards();
      expect(tunnels, hasLength(2), reason: 'restore is additive');
      expect(
        tunnels.last.serverId,
        servers.last.id,
        reason: 'the restored tunnel must follow the restored host',
      );
      vm.dispose();
    });

    test('a restored tunnel never comes back set to auto-start', () async {
      // A backup carried to a new device would otherwise open ports on it at first launch, before
      // its owner had seen the tunnel exists.
      await repo.insertServer(server(name: 'nas'));
      await addTunnel();
      final vm = await boot();
      vm
        ..selectNone()
        ..toggleSection(BackupSection.portForwards, enabled: true);
      final contents = await vm.exportBackup('a-long-enough-passphrase');
      await settle();

      await vm.importBackup(contents!, 'a-long-enough-passphrase');
      await settle();

      expect((await repo.getAllPortForwards()).last.autoStart, isFalse);
      vm.dispose();
    });

    test('a tunnel whose host is missing is skipped and counted, not guessed at', () async {
      // Restoring it against an arbitrary host would forward a port to a machine the user never
      // chose — the same reasoning as an orphaned alert rule, with a worse failure mode.
      final vm = await boot();
      final json = jsonEncode({
        'portForwards': [
          {
            'serverId': 42,
            'name': 'orphan',
            'kind': 'local',
            'bindHost': '127.0.0.1',
            'bindPort': 9000,
            'destHost': '10.0.0.9',
            'destPort': 80,
            'autoStart': false,
          },
        ],
      });

      final counts = await vm.importBackup(json, '');
      await settle();

      expect(counts!['portForwardsSkipped'], 1);
      expect(await repo.getAllPortForwards(), isEmpty);
      expect(vm.status, contains('tunnel(s) were skipped'));
      vm.dispose();
    });
  });

  group('the sections that used to be dropped', () {
    Future<int> seedRule(int serverId) => repo.insertRule(
      AlertRulesCompanion.insert(
        serverId: serverId,
        metricName: 'CPU Usage',
        thresholdValue: 90,
        severity: 'CRITICAL',
      ),
    );

    test('network shares round-trip, credentials and all', () async {
      // A share whose password was dropped restores as a row that fails on first open, which is
      // worse than not restoring it: it looks like the backup worked.
      await repo.insertNetworkShare(
        NetworkShare(
          id: 0,
          name: 'media',
          protocol: 'SMB',
          address: '10.0.0.5',
          port: 445,
          sharePath: 'films',
          workgroup: 'WORKGROUP',
          username: 'nas',
          password: 'share-secret',
          authProfileId: null,
          anonymous: false,
          useHttps: false,
          notes: 'the big one',
          lastChecked: 1234,
          lastStatus: 'online',
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restored = (await freshRepo.getAllNetworkShares()).single;
      expect(restored.name, 'media');
      expect(restored.password, 'share-secret');
      expect(restored.sharePath, 'films');
      expect(restored.notes, 'the big one');
      // Reachability is this device's observation, not the backup's.
      expect(restored.lastStatus, isEmpty);
      expect(restored.lastChecked, 0);

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('alert history comes back with the host name it was raised against', () async {
      // The name is on the row on purpose: an incident records what was true then, and a host
      // renamed since must not rewrite its own history.
      final serverId = await repo.insertServer(server(name: 'nas'));
      await repo.insertAlertHistory(
        AlertHistoryCompanion.insert(
          activeAlertId: 7,
          serverId: serverId,
          serverName: 'nas-as-it-was-called',
          metricName: 'CPU Usage',
          currentValue: 97,
          thresholdValue: 90,
          severity: 'CRITICAL',
          triggeredTime: 1000,
          historyTime: 2000,
          status: 'RESOLVED',
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restored = (await freshRepo.getAlertHistory()).single;
      expect(restored.serverName, 'nas-as-it-was-called');
      expect(restored.status, 'RESOLVED');
      // Re-pointed at the host's new id, not the old one.
      expect(restored.serverId, (await freshRepo.getAllServers()).single.id);

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('a firing alert is re-pointed at both its host and the rule that raised it', () async {
      final serverId = await repo.insertServer(server(name: 'nas'));
      final ruleId = await seedRule(serverId);
      await repo.insertAlert(
        ActiveAlertsCompanion.insert(
          ruleId: ruleId,
          serverId: serverId,
          metricName: 'CPU Usage',
          currentValue: 99,
          thresholdValue: 90,
          severity: 'CRITICAL',
          triggeredTime: 1000,
        ),
      );
      final vm = await boot();
      final contents = await vm.exportBackup('a-long-enough-passphrase');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      await freshVm.importBackup(contents!, 'a-long-enough-passphrase');

      final restoredServer = (await freshRepo.getAllServers()).single;
      final restoredRule = (await freshRepo.getAllRules()).single;
      final restored = (await freshRepo.getActiveAlerts()).single;

      expect(restored.serverId, restoredServer.id);
      expect(
        restored.ruleId,
        restoredRule.id,
        reason: 'an alert pointing at a rule id from another device explains nothing',
      );

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('a firing alert whose rule was not selected is skipped, not guessed at', () async {
      // Without its rule, the alert is a red banner about a threshold nobody can see.
      final serverId = await repo.insertServer(server(name: 'nas'));
      final ruleId = await seedRule(serverId);
      await repo.insertAlert(
        ActiveAlertsCompanion.insert(
          ruleId: ruleId,
          serverId: serverId,
          metricName: 'CPU Usage',
          currentValue: 99,
          thresholdValue: 90,
          severity: 'CRITICAL',
          triggeredTime: 1000,
        ),
      );
      final vm = await boot();
      // Hand-built: the selection model's referential closure would add the rules back, which is
      // exactly what it is for — this is the case where a document arrives without them anyway.
      final document = await exportedDocument(vm);
      document.remove('alertRules');

      final (freshDb, freshRepo, freshApp, freshVm) = await freshDevice();
      await freshVm.importBackup(jsonEncode(document), '');

      expect(await freshRepo.getActiveAlerts(), isEmpty);
      expect(
        (await freshRepo.getAllServers()),
        hasLength(1),
        reason: 'the rest of the document still restores',
      );

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('selecting everything now carries all eleven sections', () async {
      // The regression this guards: three sections were in the picker, and in the selection model's
      // dependency graph, but silently absent from the document.
      final serverId = await repo.insertServer(server(name: 'nas'));
      await seedRule(serverId);
      await repo.insertNetworkShare(
        NetworkShare(
          id: 0,
          name: 'media',
          protocol: 'SMB',
          address: '10.0.0.5',
          port: 445,
          sharePath: '',
          workgroup: '',
          username: '',
          password: '',
          authProfileId: null,
          anonymous: true,
          useHttps: false,
          notes: '',
          lastChecked: 0,
          lastStatus: '',
        ),
      );
      await repo.insertAlertHistory(
        AlertHistoryCompanion.insert(
          activeAlertId: 1,
          serverId: serverId,
          serverName: 'nas',
          metricName: 'CPU Usage',
          currentValue: 91,
          thresholdValue: 90,
          severity: 'WARNING',
          triggeredTime: 1,
          historyTime: 2,
          status: 'RESOLVED',
        ),
      );

      final vm = await boot();
      final document = await exportedDocument(vm);

      for (final key in ['networkShares', 'alertHistory']) {
        expect(document.containsKey(key), isTrue, reason: '$key is missing from a full export');
      }
      vm.dispose();
    });
  });

  test('inspecting a newer backup refuses it instead of reading half of it', () async {
    // End to end through the view model, because the check is only worth anything at the point a
    // file is actually accepted.
    final (freshDb, _, _, vm) = await freshDevice();
    final future = jsonEncode({
      'v': BackupPayload.version + 1,
      'servers': [
        {'id': 1, 'name': 'nas', 'host': '10.0.0.1'},
      ],
    });

    final inspection = await vm.inspectBackup(future, '');

    expect(inspection, isNull, reason: 'nothing may be offered for restore');
    expect(vm.error, contains('newer version'));
    vm.dispose();
    await freshDb.close();
  });

  group('the document version', () {
    // It was written into every backup and never read back, so a file from a newer build would be
    // restored as though it had this build's shape. Not hypothetical: `decode` already carries a
    // v1→v2 migration for the selection format.

    test('the current version is readable', () {
      expect(BackupPayload.incompatibleVersionMessage(BackupPayload.version), isNull);
    });

    test('an older document is readable, because migrating forward is the point', () {
      expect(BackupPayload.incompatibleVersionMessage(1), isNull);
    });

    test('a document with no version at all is treated as the oldest shape', () {
      // Predates the field, which makes it v1 — a shape this build already knows.
      expect(BackupPayload.incompatibleVersionMessage(null), isNull);
    });

    test('a newer document is refused, and says what to do', () {
      final message = BackupPayload.incompatibleVersionMessage(BackupPayload.version + 1);
      expect(message, isNotNull);
      expect(message, contains('newer version'));
      expect(message, contains('Update the app'));
    });

    test('a version that is not a number is refused rather than guessed at', () {
      expect(
        BackupPayload.incompatibleVersionMessage('banana'),
        contains('does not say what version'),
      );
    });

    test('a numeric string is read, not rejected', () {
      // JSON from another writer may quote it; that is a formatting difference, not a shape one.
      expect(BackupPayload.incompatibleVersionMessage('2'), isNull);
      expect(BackupPayload.incompatibleVersionMessage('99'), contains('newer version'));
    });
  });
}
