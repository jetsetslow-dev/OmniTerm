import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/backup/backup_envelope.dart';
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

  Server server({
    required String name,
    String host = '10.0.0.1',
    String? password = 'hunter2',
  }) =>
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

  Future<BackupViewModel> boot() async {
    await app.start();
    await Future<void>.delayed(Duration.zero);
    return BackupViewModel(app);
  }

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// Exports and returns the *payload*, decrypting when a passphrase was used.
  ///
  /// A passphrased export returns the envelope, not the document — decoding that directly would
  /// silently inspect the wrong object and every field would read as absent.
  Future<Map<String, dynamic>> exportedDocument(
    BackupViewModel vm, {
    String passphrase = 'pass',
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
      await repo.insertSetting('theme', 'dark');
      final vm = await boot();

      final document = await exportedDocument(vm, passphrase: 'pass');
      final keys = (document['settings'] as List)
          .map((s) => (s as Map)['key'] as String)
          .toList();
      expect(keys, contains('theme'));
      expect(keys, isNot(contains('app_pin')));
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
      final document = await exportedDocument(vm, passphrase: 'pass');
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
      expect(await vm.exportBackup('pass'), isNull);
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
      final contents = await vm.exportBackup('pass');

      // A different device: a fresh database with nothing in it.
      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo =
          AppRepository(freshDb, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      final freshVm = BackupViewModel(freshApp);

      await freshVm.importBackup(contents!, 'pass');

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

    test('a restored host starts unprobed rather than carrying a stale score', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      final contents = await vm.exportBackup('pass');

      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo =
          AppRepository(freshDb, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      final freshVm = BackupViewModel(freshApp);
      await freshVm.importBackup(contents!, 'pass');

      final restored = (await freshRepo.getAllServers()).single;
      expect(restored.status, 'offline');
      expect(restored.healthScore, 100,
          reason: 'a health figure for a connection never made here would be a lie');

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('is additive, so restoring the wrong file is recoverable', () async {
      // There is no undo for a restore; wiping first would make one mistake permanent.
      await repo.insertServer(server(name: 'existing'));
      final vm = await boot();
      final contents = await vm.exportBackup('pass');
      await vm.importBackup(contents!, 'pass');
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
      final contents = await vm.exportBackup('pass');

      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo =
          AppRepository(freshDb, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      // Something already occupies id 1, so the restored host cannot keep its old id.
      await freshRepo.insertServer(server(name: 'unrelated'));
      final freshVm = BackupViewModel(freshApp);
      await freshVm.importBackup(contents!, 'pass');

      final restoredHost = (await freshRepo.getAllServers()).firstWhere((s) => s.name == 'nas');
      final rule = (await freshRepo.getAllRules()).single;
      expect(rule.serverId, restoredHost.id,
          reason: 'the rule must watch the host it came with, not whichever id it used to have');

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
      final contents = await vm.exportBackup('pass');

      final freshDb = AppDatabase(NativeDatabase.memory());
      final freshRepo =
          AppRepository(freshDb, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      final freshApp = AppState(freshRepo);
      await freshApp.start();
      final freshVm = BackupViewModel(freshApp);
      await freshVm.importBackup(contents!, 'pass');

      expect((await freshRepo.getAllRules()).single.serverId, 0,
          reason: 'remapping it would narrow a rule watching every host to just one');

      freshVm.dispose();
      freshApp.dispose();
      await freshDb.close();
      vm.dispose();
    });

    test('a rule whose host is missing is skipped and reported', () async {
      // Restoring it against an arbitrary host would silently point it at the wrong machine.
      const orphan = '{"v":2,"alertRules":[{"serverId":99,"metricName":"CPU Usage",'
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
      final contents = await vm.exportBackup('pass');
      expect(BackupViewModel.looksEncrypted(contents!), isTrue);
      vm.dispose();
    });

    test('a wrong passphrase is reported as one', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      final contents = await vm.exportBackup('pass');

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

    test('an unknown section in the file is ignored, not fatal', () async {
      // A backup from a newer build must not be unreadable by an older one.
      final vm = await boot();
      const withExtra = '{"v":99,"somethingNew":[{"a":1}],'
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
    final document = await exportedDocument(vm, passphrase: 'pass');
    expect(document['scripts'], isEmpty,
        reason: 'a fresh install re-seeds these, so exporting them would duplicate defaults');
    expect(kHomelabPresets, isNotEmpty, reason: 'the presets really were seeded');
    vm.dispose();
  });
}
