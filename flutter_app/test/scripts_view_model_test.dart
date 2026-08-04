import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/script_presets.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
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

  Future<ScriptsViewModel> boot() async {
    await app.start();
    final vm = ScriptsViewModel(app);
    await vm.start();
    await Future<void>.delayed(Duration.zero);
    return vm;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('saving', () {
    test('a script is stored and appears in the quick list', () async {
      final vm = await boot();
      expect(await vm.saveScript(name: 'Uptime', command: 'uptime'), isNull);
      await settle();

      expect(vm.allScripts.single.name, 'Uptime');
      expect(vm.visibleScripts.single.name, 'Uptime');
      vm.dispose();
    });

    test('each new script gets its own row', () async {
      // The §15.3 defect in a different table: a literal 0 id under InsertMode.replace would make
      // every new script overwrite the previous one.
      final vm = await boot();
      await vm.saveScript(name: 'One', command: 'a');
      await settle();
      await vm.saveScript(name: 'Two', command: 'b');
      await settle();

      expect(vm.allScripts.map((s) => s.name), containsAll(['One', 'Two']));
      expect(vm.allScripts, hasLength(2));
      vm.dispose();
    });

    test('validation refuses incomplete scripts', () async {
      final vm = await boot();
      expect(await vm.saveScript(name: '  ', command: 'a'), contains('Name'));
      expect(await vm.saveScript(name: 'a', command: '  '), contains('Command'));
      await settle();
      expect(vm.allScripts, isEmpty);
      vm.dispose();
    });

    test('a script offered in neither list is refused', () async {
      // It would be invisible everywhere, which is almost certainly not what was meant.
      final vm = await boot();
      expect(
        await vm.saveScript(
          name: 'Ghost',
          command: 'true',
          availableForQuick: false,
          availableForFleet: false,
        ),
        contains('Quick scripts, Fleet commands, or both'),
      );
      await settle();
      expect(vm.allScripts, isEmpty);
      vm.dispose();
    });

    test('editing updates in place rather than duplicating', () async {
      final vm = await boot();
      await vm.saveScript(name: 'Uptime', command: 'uptime');
      await settle();

      final existing = vm.allScripts.single;
      await vm.saveScript(existing: existing, name: 'Uptime', command: 'uptime -p');
      await settle();

      expect(vm.allScripts, hasLength(1));
      expect(vm.allScripts.single.command, 'uptime -p');
      expect(vm.allScripts.single.id, existing.id);
      vm.dispose();
    });

    test('a blank emoji falls back rather than rendering nothing', () async {
      final vm = await boot();
      await vm.saveScript(name: 'Uptime', command: 'uptime', emoji: '   ');
      await settle();
      expect(vm.allScripts.single.emoji, isNotEmpty);
      vm.dispose();
    });
  });

  group('the two lists', () {
    test('quick and fleet scripts are separated', () async {
      final vm = await boot();
      await vm.saveScript(name: 'Quick', command: 'a');
      await vm.saveScript(
        name: 'Broadcast',
        command: 'b',
        availableForQuick: false,
        availableForFleet: true,
      );
      await settle();

      expect(vm.visibleScripts.map((s) => s.name), ['Quick']);
      vm.activeTab = ScriptsTab.fleet;
      expect(vm.visibleScripts.map((s) => s.name), ['Broadcast']);
      vm.dispose();
    });

    test('a script can be offered in both', () async {
      final vm = await boot();
      await vm.saveScript(
        name: 'Both',
        command: 'a',
        availableForQuick: true,
        availableForFleet: true,
      );
      await settle();

      expect(vm.visibleScripts.map((s) => s.name), ['Both']);
      vm.activeTab = ScriptsTab.fleet;
      expect(vm.visibleScripts.map((s) => s.name), ['Both']);
      vm.dispose();
    });

    test('a script cannot be removed from its last list', () async {
      // Turning off the only list it appears in would hide it with no way back.
      final vm = await boot();
      await vm.saveScript(name: 'Quick', command: 'a');
      await settle();

      await vm.setAvailableForQuick(vm.allScripts.single, false);
      await settle();
      expect(vm.allScripts.single.availableForQuick, isTrue);
      vm.dispose();
    });

    test('grouping keeps the DAO ordering within a category', () async {
      final vm = await boot();
      await vm.saveScript(name: 'B', command: 'b', category: 'Disk');
      await vm.saveScript(name: 'A', command: 'a', category: 'CPU');
      await settle();

      expect(vm.groupedScripts.keys, containsAll(['CPU', 'Disk']));
      expect(vm.groupedScripts['CPU']!.single.name, 'A');
      vm.dispose();
    });

    test('an empty category is filed under General', () async {
      final vm = await boot();
      await vm.saveScript(name: 'Loose', command: 'a', category: '   ');
      await settle();
      expect(vm.groupedScripts.keys, ['General']);
      vm.dispose();
    });
  });

  group('preset families', () {
    test('enabling seeds the whole family and sets the flag', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      expect(vm.fleetPresetsEnabled, isTrue);
      expect(await repo.getSetting(fleetPresetsSetting), 'true');
      expect(vm.allScripts, hasLength(kFleetPresets.length));
      expect(
        vm.allScripts.map((s) => s.presetKey).toSet(),
        kFleetPresets.map((p) => p.presetKey).toSet(),
      );
      vm.dispose();
    });

    test('enabling twice does not duplicate rows', () async {
      // Reusing the existing row id is what stops the family accumulating on every toggle.
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      expect(vm.allScripts, hasLength(kFleetPresets.length));
      vm.dispose();
    });

    test('disabling removes only that family', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await settle();
      expect(vm.allScripts, hasLength(kFleetPresets.length + kHomelabPresets.length));

      await vm.setPresetsEnabled(fleet: true, enabled: false);
      await settle();

      expect(vm.allScripts, hasLength(kHomelabPresets.length));
      expect(vm.allScripts.every((s) => s.presetKey!.startsWith('homelab.')), isTrue);
      vm.dispose();
    });

    test('disabling keeps the user\'s own scripts', () async {
      final vm = await boot();
      await vm.saveScript(name: 'Mine', command: 'echo hi');
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      await vm.setPresetsEnabled(fleet: true, enabled: false);
      await settle();

      expect(vm.allScripts.map((s) => s.name), ['Mine']);
      vm.dispose();
    });

    test('a renamed preset is still removed, because matching is by key', () async {
      // Matching on name would miss it — and worse, could delete a user script sharing a name.
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      final preset = vm.allScripts.firstWhere((s) => s.presetKey == 'fleet.cpu');
      await vm.saveScript(existing: preset, name: 'My CPU check', command: preset.command);
      await settle();

      await vm.setPresetsEnabled(fleet: true, enabled: false);
      await settle();
      expect(vm.allScripts.any((s) => s.name == 'My CPU check'), isFalse);
      vm.dispose();
    });

    test('re-enabling resets an edited preset, as the confirmation warns', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      final preset = vm.allScripts.firstWhere((s) => s.presetKey == 'fleet.disk');
      await vm.saveScript(existing: preset, name: preset.name, command: 'my own command');
      await settle();
      expect(
        vm.allScripts.firstWhere((s) => s.presetKey == 'fleet.disk').command,
        'my own command',
      );

      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      expect(
        vm.allScripts.firstWhere((s) => s.presetKey == 'fleet.disk').command,
        kFleetPresets.firstWhere((p) => p.presetKey == 'fleet.disk').command,
      );
      vm.dispose();
    });

    test('the flags are read back on a later start', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await settle();
      vm.dispose();

      final reopened = ScriptsViewModel(app);
      await reopened.start();
      expect(reopened.homelabPresetsEnabled, isTrue);
      expect(reopened.fleetPresetsEnabled, isFalse);
      reopened.dispose();
    });
  });

  group('pristine detection', () {
    test('an untouched preset is recognised', () async {
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();
      expect(vm.isPristinePresetScript(vm.allScripts.first), isTrue);
      vm.dispose();
    });

    test('an edited preset is not', () async {
      // Once edited it is effectively the user's, and a backup must preserve it.
      final vm = await boot();
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await settle();

      final preset = vm.allScripts.firstWhere((s) => s.presetKey == 'fleet.cpu');
      await vm.saveScript(existing: preset, name: preset.name, command: 'changed');
      await settle();

      expect(
        vm.isPristinePresetScript(vm.allScripts.firstWhere((s) => s.presetKey == 'fleet.cpu')),
        isFalse,
      );
      vm.dispose();
    });

    test('a user script is never pristine', () async {
      final vm = await boot();
      await vm.saveScript(name: 'Mine', command: 'a');
      await settle();
      expect(vm.isPristinePresetScript(vm.allScripts.single), isFalse);
      vm.dispose();
    });
  });

  group('the Fleet preset picker', () {
    test('offers every fleet-enabled script, ordered', () async {
      final vm = await boot();
      await vm.saveScript(
        name: 'Zulu',
        command: 'z',
        availableForQuick: false,
        availableForFleet: true,
      );
      await vm.saveScript(
        name: 'Alpha',
        command: 'a',
        availableForQuick: false,
        availableForFleet: true,
      );
      await vm.saveScript(name: 'QuickOnly', command: 'q');
      await settle();

      expect(vm.fleetPresetScripts.map((s) => s.name), ['Alpha', 'Zulu']);
      vm.dispose();
    });

    test('is empty until something is offered for broadcast', () async {
      final vm = await boot();
      await vm.saveScript(name: 'QuickOnly', command: 'q');
      await settle();
      expect(vm.fleetPresetScripts, isEmpty);
      vm.dispose();
    });
  });

  test('deleting removes the script', () async {
    final vm = await boot();
    await vm.saveScript(name: 'Doomed', command: 'a');
    await settle();

    await vm.deleteScript(vm.allScripts.single);
    await settle();
    expect(vm.allScripts, isEmpty);
    vm.dispose();
  });
}
