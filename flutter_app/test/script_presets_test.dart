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

    test('the presets a fresh install seeds are self-consistent', () {
      // Deliberately not asserted against the Kotlin's back-stamp list. That list exists because
      // `presetKey` was added to an app that already had rows on devices; a fresh Flutter install
      // seeds every preset with its key from the start. Requiring a legacy counterpart would make
      // any *new* preset fail this suite for a reason that has nothing to do with it working.
      // See MIGRATION.md §16.4.
      for (final preset in kAllScriptPresets) {
        expect(preset.presetKey, matches(RegExp(r'^(fleet|homelab)\.')), reason: preset.presetKey);
      }
    });

    test('a script seeded by an older Android build is still recognised', () {
      // A data-compatibility check, not a feature requirement: the upgrade path reads an existing
      // database, and the migration matches on name + category, so those must still agree for the
      // presets that build actually wrote. A preset with no legacy counterpart is not a gap.
      final byKey = {for (final p in kAllScriptPresets) p.presetKey: p};
      for (final legacy in kLegacyScriptPresets) {
        final preset = byKey[legacy.key];
        if (preset == null) continue;
        expect(preset.name, legacy.name, reason: legacy.key);
        expect(preset.category, legacy.category, reason: legacy.key);
      }
    });

    test('the two families are distinct and cannot overlap', () {
      // The toggles remove by key, so a key appearing in both families would be deleted by either.
      final fleet = kFleetPresets.map((p) => p.presetKey).toSet();
      final homelab = kHomelabPresets.map((p) => p.presetKey).toSet();
      expect(fleet.intersection(homelab), isEmpty);
      expect(fleetPresetsSetting, isNot(homelabPresetsSetting));
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
