import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/health_scoring.dart';

/// Ported from `HealthScoringTest.kt`, with the same fixtures and expectations.
void main() {
  const c = HealthScoringConfig.defaults;

  test('default score deducts per tier', () {
    // CPU 95 (critical -30), MEM 40 (none), disk 40 (none), latency 10 (none) → 70.
    expect(c.score(95, 40, 40, 10), 70);
    // Healthy host: full marks.
    expect(c.score(10, 20, 30, 5), 100);
  });

  test('breakdown lists only deducting factors', () {
    final b = c.breakdown(95, 85, 10, 5, online: true);
    // CPU critical (-30) and Memory high (-12) deduct; disk & latency don't.
    expect(b.factors, hasLength(2));
    expect(b.score, 58);
    expect(b.offline, isFalse);
    expect(b.factors.any((f) => f.label.startsWith('CPU') && f.penalty == 30), isTrue);
    expect(b.factors.any((f) => f.label.startsWith('Memory') && f.penalty == 12), isTrue);
  });

  test('a healthy host has an empty breakdown', () {
    final b = c.breakdown(10, 20, 30, 5, online: true);
    expect(b.healthy, isTrue);
    expect(b.factors, isEmpty);
    expect(b.score, 100);
  });

  test('offline forces zero', () {
    final b = c.breakdown(0, 0, 0, 0, online: false);
    expect(b.offline, isTrue);
    expect(b.score, 0);
    expect(b.healthy, isFalse, reason: 'an unreachable host is not healthy');
  });

  test('the score floor is 0, never negative', () {
    // Every metric at its critical tier: 30 + 25 + 30 + 15 = 100 penalty.
    expect(c.score(99, 99, 99, 9999), 0);
  });

  test('a factor label names the tier and the threshold it crossed', () {
    final b = c.breakdown(95, 10, 10, 5, online: true);
    expect(b.factors.single.label, 'CPU 95% — critical (≥90%)');
  });

  test('tier boundaries are inclusive', () {
    // Exactly at warnAt (50) already deducts the warn penalty.
    expect(c.cpu.penaltyFor(50), 5);
    expect(c.cpu.penaltyFor(49.9), 0);
    expect(c.cpu.tierLabel(50), 'elevated');
    expect(c.cpu.tierLabel(49.9), isNull);
  });

  group('encode / decode', () {
    test('round-trips a customised config', () {
      final custom = c.copyWith(cpu: c.cpu.copyWith(criticalPenalty: 40));
      expect(HealthScoringConfig.decode(custom.encode()), custom);
    });

    test('blank or garbage input falls back to the defaults rather than throwing', () {
      expect(HealthScoringConfig.decode(null), HealthScoringConfig.defaults);
      expect(HealthScoringConfig.decode(''), HealthScoringConfig.defaults);
      expect(HealthScoringConfig.decode('   '), HealthScoringConfig.defaults);
      expect(HealthScoringConfig.decode('nonsense'), HealthScoringConfig.defaults);
      expect(HealthScoringConfig.decode('cpu:not,a,number,at,all,here'),
          HealthScoringConfig.defaults);
    });

    test('a partial config keeps the defaults for the metrics it omits', () {
      final decoded = HealthScoringConfig.decode('cpu:10.0,20.0,30.0,1,2,3');
      expect(decoded.cpu, const MetricTiers(10, 20, 30, 1, 2, 3));
      expect(decoded.mem, HealthScoringConfig.defaults.mem);
      expect(decoded.disk, HealthScoringConfig.defaults.disk);
      expect(decoded.latency, HealthScoringConfig.defaults.latency);
    });

    test('the encoding is the exact string shape the Kotlin app persisted', () {
      // Kotlin renders Float as "50.0"; the stored value must not become "50".
      expect(
        HealthScoringConfig.defaults.encode(),
        'cpu:50.0,75.0,90.0,5,15,30;mem:70.0,80.0,90.0,5,12,25;'
        'disk:80.0,90.0,95.0,10,25,30;lat:50.0,100.0,200.0,3,7,15',
      );
    });
  });
}
