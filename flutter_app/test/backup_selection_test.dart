import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/backup_selection.dart';

/// A backup whose child rows reference parents that were not exported restores into dangling
/// references — rules watching hosts that do not exist, incidents pointing at nothing. The closure
/// rules are what stop that being possible, from either direction.
void main() {
  group('referential closure', () {
    test('alert rules pull in hosts', () {
      final selection = const BackupSelection.none()
          .toggled(BackupSection.alertRules, enabled: true);
      expect(selection.contains(BackupSection.servers), isTrue);
    });

    test('firing alerts pull in both their rule and its host', () {
      // Two levels: the incident needs the rule, and the rule needs the host.
      final selection = const BackupSelection.none()
          .toggled(BackupSection.activeAlerts, enabled: true);
      expect(selection.contains(BackupSection.alertRules), isTrue);
      expect(selection.contains(BackupSection.servers), isTrue);
    });

    test('port forwards and history pull in hosts', () {
      for (final section in [BackupSection.portForwards, BackupSection.alertHistory]) {
        final selection = const BackupSelection.none().toggled(section, enabled: true);
        expect(selection.contains(BackupSection.servers), isTrue, reason: section.name);
      }
    });

    test('independent sections pull in nothing', () {
      for (final section in [
        BackupSection.sshKeys,
        BackupSection.credentialProfiles,
        BackupSection.scripts,
        BackupSection.wolTargets,
        BackupSection.networkShares,
        BackupSection.settings,
      ]) {
        final selection = const BackupSelection.none().toggled(section, enabled: true);
        expect(selection.sections, {section}, reason: section.name);
      }
    });

    test('applying closure twice changes nothing', () {
      final once = BackupSelection.all().withReferentialClosure();
      expect(once.withReferentialClosure(), once);
    });
  });

  group('turning a section off', () {
    test('drops everything that depended on it', () {
      // The other direction: leaving alert rules selected while dropping hosts gives the same
      // unrestorable backup.
      final selection = BackupSelection.all().toggled(BackupSection.servers, enabled: false);

      expect(selection.contains(BackupSection.servers), isFalse);
      expect(selection.contains(BackupSection.alertRules), isFalse);
      expect(selection.contains(BackupSection.activeAlerts), isFalse);
      expect(selection.contains(BackupSection.alertHistory), isFalse);
      expect(selection.contains(BackupSection.portForwards), isFalse);
    });

    test('keeps sections that did not depend on it', () {
      final selection = BackupSelection.all().toggled(BackupSection.servers, enabled: false);
      expect(selection.contains(BackupSection.sshKeys), isTrue);
      expect(selection.contains(BackupSection.scripts), isTrue);
      expect(selection.contains(BackupSection.settings), isTrue);
    });

    test('dropping alert rules drops incidents but keeps hosts', () {
      final selection = BackupSelection.all().toggled(BackupSection.alertRules, enabled: false);
      expect(selection.contains(BackupSection.activeAlerts), isFalse);
      expect(selection.contains(BackupSection.servers), isTrue,
          reason: 'hosts stand on their own');
    });

    test('dropping a leaf affects nothing else', () {
      final selection = BackupSelection.all().toggled(BackupSection.activeAlerts, enabled: false);
      expect(selection.contains(BackupSection.alertRules), isTrue);
      expect(selection.contains(BackupSection.servers), isTrue);
    });
  });

  group('sensitivity', () {
    test('anything naming a host or carrying a credential counts', () {
      for (final section in [
        BackupSection.servers,
        BackupSection.sshKeys,
        BackupSection.credentialProfiles,
        BackupSection.scripts,
        BackupSection.alertRules,
        BackupSection.networkShares,
        BackupSection.portForwards,
      ]) {
        expect(
          const BackupSelection.none().toggled(section, enabled: true).hasSensitiveData,
          isTrue,
          reason: section.name,
        );
      }
    });

    test('settings alone are not sensitive', () {
      expect(
        const BackupSelection.none()
            .toggled(BackupSection.settings, enabled: true)
            .hasSensitiveData,
        isFalse,
      );
    });

    test('an empty selection is not sensitive', () {
      expect(const BackupSelection.none().hasSensitiveData, isFalse);
      expect(const BackupSelection.none().isEmpty, isTrue);
    });

    test('a full backup is always sensitive', () {
      expect(BackupSelection.all().hasSensitiveData, isTrue);
    });
  });

  group('remapServerId', () {
    test('a mapped host resolves to its restored id', () {
      expect(remapServerId(7, {7: 42}), 42);
    });

    test('zero is preserved, because it is the fleet-wide scope', () {
      // Remapping it would turn a rule watching every machine into one watching whichever host
      // happened to restore first.
      expect(remapServerId(0, {7: 42}), 0);
      expect(remapServerId(0, const {}), 0);
    });

    test('an unmapped host resolves to nothing, so the row is dropped', () {
      // Pointing it somewhere arbitrary would silently reassign a rule to the wrong machine.
      expect(remapServerId(9, {7: 42}), isNull);
    });
  });

  test('dependents are the inverse of dependencies', () {
    for (final section in BackupSection.values) {
      for (final dependency in BackupSelection.dependenciesOf(section)) {
        expect(
          BackupSelection.dependentsOf(dependency),
          contains(section),
          reason: '${section.name} depends on ${dependency.name}',
        );
      }
    }
  });

  test('every section has a label to show', () {
    for (final section in BackupSection.values) {
      expect(section.label.trim(), isNotEmpty, reason: section.name);
    }
  });
}
