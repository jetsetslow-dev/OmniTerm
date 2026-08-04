import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/legacy_presets.dart';
import 'package:omniterm/data/script_presets.dart';

/// The preset keys are historical facts about databases already on users' devices: a row is claimed
/// as "the app's" by its key, so a changed key means a "disable presets" silently leaves rows behind.
void main() {
  group('identity', () {
    test('every key is unique', () {
      final keys = kAllScriptPresets.map((p) => p.presetKey).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('every preset key is also known to the legacy migration', () {
      // The 19 → 20 migration back-stamps these keys onto rows seeded before the column existed.
      // A preset here with no legacy counterpart would not be recognised on an upgraded install.
      final legacy = kLegacyScriptPresets.map((p) => p.key).toSet();
      for (final preset in kAllScriptPresets) {
        expect(legacy, contains(preset.presetKey), reason: preset.presetKey);
      }
    });

    test('the legacy list and the seed list describe the same set', () {
      final seeded = kAllScriptPresets.map((p) => p.presetKey).toSet();
      final legacy = kLegacyScriptPresets.map((p) => p.key).toSet();
      expect(seeded, legacy);
    });

    test('the legacy name matches what is seeded', () {
      // The migration matches on name + category, so a drift between the two lists would leave a
      // row unclaimed on an upgraded install.
      final byKey = {for (final p in kAllScriptPresets) p.presetKey: p};
      for (final legacy in kLegacyScriptPresets) {
        expect(byKey[legacy.key]!.name, legacy.name, reason: legacy.key);
        expect(byKey[legacy.key]!.category, legacy.category, reason: legacy.key);
      }
    });

    test('each family maps to its own settings key', () {
      final byKey = {for (final p in kLegacyScriptPresets) p.key: p};
      for (final preset in kFleetPresets) {
        expect(byKey[preset.presetKey]!.familySetting, fleetPresetsSetting);
      }
      for (final preset in kHomelabPresets) {
        expect(byKey[preset.presetKey]!.familySetting, homelabPresetsSetting);
      }
    });
  });

  group('availability', () {
    test('fleet presets are broadcast-only', () {
      // Showing a fleet-shaped command in the per-host Quick Scripts row would run it on one host,
      // which is not what it was written for.
      for (final preset in kFleetPresets) {
        expect(preset.availableForFleet, isTrue, reason: preset.presetKey);
        expect(preset.availableForQuick, isFalse, reason: preset.presetKey);
      }
    });

    test('homelab presets are quick-only', () {
      for (final preset in kHomelabPresets) {
        expect(preset.availableForQuick, isTrue, reason: preset.presetKey);
        expect(preset.availableForFleet, isFalse, reason: preset.presetKey);
      }
    });

    test('fleet presets keep a stable display order', () {
      expect(
        kFleetPresets.map((p) => p.sortOrder),
        List.generate(kFleetPresets.length, (i) => i),
      );
    });
  });

  group('the commands themselves', () {
    test('fleet presets fall through to a Windows equivalent', () {
      // A fleet is rarely all one OS, and a command that fails on a third of the hosts is not a
      // useful preset. The container one is the exception, and correctly so: docker and podman
      // present the same CLI on Windows, so there is nothing to fall back to.
      for (final preset in kFleetPresets.where((p) => p.presetKey != 'fleet.containers')) {
        expect(preset.command, contains('powershell'), reason: preset.presetKey);
      }
      final containers =
          kFleetPresets.firstWhere((p) => p.presetKey == 'fleet.containers');
      expect(containers.command, contains('podman'));
    });

    test('the container preset keeps its literal tab escape', () {
      // `\t` must reach the runtime as two characters for the Go template to format columns.
      final containers =
          kFleetPresets.firstWhere((p) => p.presetKey == 'fleet.containers');
      expect(containers.command, contains(r'{{.Names}}\t{{.Status}}'));
      expect(containers.command, isNot(contains('\t')),
          reason: 'a real tab would break the template');
    });

    test('shell variables survived Dart interpolation', () {
      // A mis-escaped `$` reads correctly in source and expands to nothing on the host.
      for (final preset in kAllScriptPresets) {
        expect(preset.command, isNot(contains(r'\$')), reason: preset.presetKey);
      }
      final temperature =
          kHomelabPresets.firstWhere((p) => p.presetKey == 'homelab.temperature');
      expect(temperature.command, contains(r'$(uname -s 2>/dev/null)'));
      expect(temperature.command, contains(r'"$max"'));
      expect(temperature.command, contains(r'v=$(cat "$f" 2>/dev/null)'));
    });

    test('the temperature preset explains itself on a host with no sensor', () {
      // Printing nothing would be indistinguishable from a failed command.
      final temperature =
          kHomelabPresets.firstWhere((p) => p.presetKey == 'homelab.temperature');
      expect(temperature.command, contains('No thermal sensor exposed'));
      expect(temperature.command, contains('vcgencmd'));
      expect(temperature.command, contains('supports Linux hosts'));
    });

    test('no command is empty', () {
      for (final preset in kAllScriptPresets) {
        expect(preset.command.trim(), isNotEmpty, reason: preset.presetKey);
        expect(preset.name.trim(), isNotEmpty, reason: preset.presetKey);
        expect(preset.emoji.trim(), isNotEmpty, reason: preset.presetKey);
      }
    });
  });

  group('isPristinePreset', () {
    final preset = kHomelabPresets.first;

    test('an untouched row is the app\'s', () {
      expect(isPristinePreset(preset, preset.name, preset.command), isTrue);
    });

    test('an edited command makes it the user\'s', () {
      // Once edited it must survive both a backup and a "disable presets".
      expect(isPristinePreset(preset, preset.name, 'qm list --full'), isFalse);
    });

    test('a renamed row makes it the user\'s too', () {
      expect(isPristinePreset(preset, 'My VMs', preset.command), isFalse);
    });
  });
}
