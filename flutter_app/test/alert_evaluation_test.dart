import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/alert_presets.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/legacy_presets.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/domain/alert_evaluation.dart';

/// A rule that fires on noise gets muted and then ignored; one that never fires is worse than not
/// existing. These tests pin which value each rule actually looks at.
void main() {
  AlertRule rule({
    String metric = 'CPU Usage',
    double threshold = 90,
    String mountPoint = '/',
    String window = '5m',
    String severity = 'WARNING',
    int serverId = 0,
    bool enabled = true,
    String? presetKey,
  }) =>
      AlertRule(
        id: 1,
        serverId: serverId,
        metricName: metric,
        mountPoint: mountPoint,
        thresholdValue: threshold,
        severity: severity,
        triggerWindow: window,
        enabled: enabled,
        notes: '',
        presetKey: presetKey,
      );

  DiskUsage mount(String path, {required int total, required int used}) =>
      DiskUsage(mount: path, filesystem: '', totalBytes: total, usedBytes: used);

  group('currentValueFor', () {
    test('reads the matching metric', () {
      const sample = AlertSample(
        cpuPercent: 42,
        memoryPercent: 71,
        latencyMs: 130,
        cpuTempC: 55,
      );
      expect(currentValueFor(rule(metric: 'CPU Usage'), sample), 42);
      expect(currentValueFor(rule(metric: 'Memory Usage'), sample), 71);
      expect(currentValueFor(rule(metric: 'Latency'), sample), 130);
      expect(currentValueFor(rule(metric: 'Temperature'), sample), 55);
    });

    test('an unknown metric yields null rather than a wrong number', () {
      expect(currentValueFor(rule(metric: 'Gremlins'), const AlertSample()), isNull);
    });

    group('temperature', () {
      test('a host with no sensor reports null, so the rule never fires there', () {
        // Substituting 0 would make every VM look permanently cool — the same outcome by accident
        // rather than by design.
        const noSensor = AlertSample(cpuPercent: 99);
        expect(currentValueFor(rule(metric: 'Temperature'), noSensor), isNull);
        expect(isOverThreshold(rule(metric: 'Temperature', threshold: 1), noSensor), isFalse);
      });

      test('a host with a sensor is evaluated normally', () {
        const hot = AlertSample(cpuTempC: 85);
        expect(isOverThreshold(rule(metric: 'Temperature', threshold: 80), hot), isTrue);
      });
    });

    group('disk', () {
      final sample = AlertSample(
        diskPercent: 40,
        mounts: [
          mount('/', total: 100, used: 40),
          mount('/srv', total: 100, used: 95),
        ],
      );

      test('a rule watches its own mount, not the aggregate', () {
        // Reporting the root figure under a /srv rule would name the wrong filesystem.
        expect(currentValueFor(rule(metric: 'Disk Usage', mountPoint: '/srv'), sample), 95);
        expect(currentValueFor(rule(metric: 'Disk Usage', mountPoint: '/'), sample), 40);
      });

      test('the aggregate is a fallback for the root mount only', () {
        const noMounts = AlertSample(diskPercent: 88);
        expect(currentValueFor(rule(metric: 'Disk Usage', mountPoint: '/'), noMounts), 88);
        expect(currentValueFor(rule(metric: 'Disk Usage', mountPoint: ''), noMounts), 88);
        expect(
          currentValueFor(rule(metric: 'Disk Usage', mountPoint: '/srv'), noMounts),
          isNull,
          reason: 'the root figure says nothing about /srv',
        );
      });

      test('a mount that disappeared reports null rather than the root value', () {
        expect(
          currentValueFor(rule(metric: 'Disk Usage', mountPoint: '/gone'), sample),
          isNull,
        );
      });
    });
  });

  group('isOverThreshold', () {
    test('strictly above, so a threshold of 90 does not fire at exactly 90', () {
      expect(isOverThreshold(rule(threshold: 90), const AlertSample(cpuPercent: 90)), isFalse);
      expect(isOverThreshold(rule(threshold: 90), const AlertSample(cpuPercent: 90.1)), isTrue);
    });
  });

  group('triggerWindowMs', () {
    test('parses the stored windows', () {
      expect(triggerWindowMs('2m'), 120000);
      expect(triggerWindowMs('15m'), 900000);
      expect(triggerWindowMs(' 5m '), 300000);
    });

    test('an unparseable window fires immediately rather than never', () {
      // A rule that alerts too eagerly gets noticed and fixed; one that silently never fires does
      // not.
      expect(triggerWindowMs('soon'), 0);
      expect(triggerWindowMs(''), 0);
    });
  });

  group('staleGapMs', () {
    test('three poll intervals, floored at 90 seconds', () {
      // A fast poll must not make the gap so short that an ordinary pause discards the window.
      expect(staleGapMs(15000), 90000);
      expect(staleGapMs(60000), 180000);
      expect(staleGapMs(1000), 90000);
    });
  });

  group('ruleEditInvalidatesIncident', () {
    final before = rule();

    test('changing what it watches invalidates', () {
      for (final after in [
        before.copyWith(metricName: 'Memory Usage'),
        before.copyWith(mountPoint: '/srv'),
        before.copyWith(thresholdValue: 50),
        before.copyWith(severity: 'CRITICAL'),
        before.copyWith(triggerWindow: '15m'),
        before.copyWith(serverId: 4),
        before.copyWith(enabled: false),
      ]) {
        expect(ruleEditInvalidatesIncident(before, after), isTrue,
            reason: 'the incident was raised under different terms');
      }
    });

    test('an unrelated edit keeps the incident', () {
      // Clearing a live incident because a note changed would lose a real signal.
      expect(
        ruleEditInvalidatesIncident(before, before.copyWith(notes: 'watch this one')),
        isFalse,
      );
      expect(
        ruleEditInvalidatesIncident(
          before,
          before.copyWith(presetKey: const Value('alert.cpu')),
        ),
        isFalse,
      );
    });
  });

  group('presentation', () {
    test('units match the metric', () {
      expect(unitFor('Latency'), 'ms');
      expect(unitFor('Temperature'), '°');
      expect(unitFor('CPU Usage'), '%');
    });

    test('a rule describes what it watches', () {
      expect(describeRule(rule(threshold: 90, window: '5m')), 'CPU Usage above 90% for 5m');
      expect(
        describeRule(rule(metric: 'Disk Usage', mountPoint: '/srv', threshold: 80)),
        'Disk Usage on /srv above 80% for 5m',
      );
      expect(
        describeRule(rule(metric: 'Latency', threshold: 250)),
        'Latency above 250ms for 5m',
      );
    });

    test('a root disk rule does not repeat the mount', () {
      expect(describeRule(rule(metric: 'Disk Usage', mountPoint: '/')), contains('on /'));
    });
  });

  group('the default rules', () {
    test('every preset watches a metric the evaluator understands', () {
      for (final preset in kAlertPresets) {
        expect(alertMetrics, contains(preset.metricName), reason: preset.presetKey);
        expect(alertSeverities, contains(preset.severity), reason: preset.presetKey);
      }
    });

    test('keys are unique', () {
      final keys = kAlertPresets.map((p) => p.presetKey).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('the presets a fresh install seeds are self-consistent', () {
      // Deliberately NOT asserted against the Kotlin's back-stamp list. That list exists because
      // `presetKey` was added to an app that already had rows in the wild; a fresh Flutter install
      // seeds every preset with its key from the start, so there is nothing to back-stamp and no
      // reason for one preset to be special. See MIGRATION.md §16.4.
      for (final preset in kAlertPresets) {
        expect(preset.presetKey, startsWith('alert.'), reason: preset.presetKey);
        expect(preset.thresholdValue, greaterThan(0), reason: preset.presetKey);
      }
    });

    test('a rule seeded by an older Android build is still recognised', () {
      // This is a *data-compatibility* check, not a feature requirement: the upgrade path reads an
      // existing database, and a row the old app seeded must still be claimed by the toggle. Only
      // the presets that build ever wrote are covered — a preset with no legacy counterpart is not
      // a gap, it simply never existed there.
      final byKey = {for (final p in kAlertPresets) p.presetKey: p};
      for (final legacy in kLegacyRulePresets) {
        final preset = byKey[legacy.key];
        if (preset == null) continue;
        expect(preset.metricName, legacy.metric, reason: legacy.key);
        expect(preset.thresholdValue, legacy.threshold, reason: legacy.key);
        expect(preset.severity, legacy.severity, reason: legacy.key);
      }
    });

    test('no percentage default is unreachable', () {
      for (final preset in kAlertPresets.where((p) => unitFor(p.metricName) == '%')) {
        expect(preset.thresholdValue, lessThanOrEqualTo(100), reason: preset.presetKey);
      }
    });
  });

  group('isPristineAlertPreset', () {
    final preset = kAlertPresets.first;

    test('an untuned rule is the app\'s', () {
      expect(
        isPristineAlertPreset(preset, preset.thresholdValue, preset.severity),
        isTrue,
      );
    });

    test('a retuned threshold or severity makes it the user\'s', () {
      // Once retuned it must survive both a backup and a "disable defaults".
      expect(isPristineAlertPreset(preset, 75, preset.severity), isFalse);
      expect(isPristineAlertPreset(preset, preset.thresholdValue, 'WARNING'), isFalse);
    });
  });
}
