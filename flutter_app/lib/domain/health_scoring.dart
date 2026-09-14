/// Host health scoring, ported from `data/HealthScoring.kt`.
///
/// Pure arithmetic over four metrics, with user-tunable thresholds and weights. The encoded form is
/// persisted in `app_settings`, so [HealthScoringConfig.encode]/[HealthScoringConfig.decode] are a
/// storage-compatibility surface: they must round-trip the exact strings the Kotlin app wrote.
library;

/// One metric's three escalating (threshold, penalty) tiers used to score host health.
///
/// A reading at or above a tier's threshold subtracts that tier's penalty (the highest matching
/// tier wins).
class MetricTiers {
  const MetricTiers(
    this.warnAt,
    this.highAt,
    this.criticalAt,
    this.warnPenalty,
    this.highPenalty,
    this.criticalPenalty,
  );

  final double warnAt;
  final double highAt;
  final double criticalAt;
  final int warnPenalty;
  final int highPenalty;
  final int criticalPenalty;

  int penaltyFor(double value) {
    if (value >= criticalAt) return criticalPenalty;
    if (value >= highAt) return highPenalty;
    if (value >= warnAt) return warnPenalty;
    return 0;
  }

  String? tierLabel(double value) {
    if (value >= criticalAt) return 'critical';
    if (value >= highAt) return 'high';
    if (value >= warnAt) return 'elevated';
    return null;
  }

  double? tierThreshold(double value) {
    if (value >= criticalAt) return criticalAt;
    if (value >= highAt) return highAt;
    if (value >= warnAt) return warnAt;
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MetricTiers &&
      other.warnAt == warnAt &&
      other.highAt == highAt &&
      other.criticalAt == criticalAt &&
      other.warnPenalty == warnPenalty &&
      other.highPenalty == highPenalty &&
      other.criticalPenalty == criticalPenalty;

  @override
  int get hashCode =>
      Object.hash(warnAt, highAt, criticalAt, warnPenalty, highPenalty, criticalPenalty);

  MetricTiers copyWith({
    double? warnAt,
    double? highAt,
    double? criticalAt,
    int? warnPenalty,
    int? highPenalty,
    int? criticalPenalty,
  }) => MetricTiers(
    warnAt ?? this.warnAt,
    highAt ?? this.highAt,
    criticalAt ?? this.criticalAt,
    warnPenalty ?? this.warnPenalty,
    highPenalty ?? this.highPenalty,
    criticalPenalty ?? this.criticalPenalty,
  );
}

/// A single contributing line in a host's score breakdown.
class HealthFactor {
  const HealthFactor(this.label, this.penalty);

  final String label;
  final int penalty;

  @override
  bool operator ==(Object other) =>
      other is HealthFactor && other.label == label && other.penalty == penalty;

  @override
  int get hashCode => Object.hash(label, penalty);
}

/// Full explanation of a host's current score: which metrics deducted points, and how many.
class HealthBreakdown {
  const HealthBreakdown(this.score, {required this.offline, required this.factors});

  final int score;
  final bool offline;
  final List<HealthFactor> factors;

  bool get healthy => !offline && factors.isEmpty;
}

/// User-tunable health-scoring configuration.
///
/// The score starts at 100 and each metric subtracts a penalty based on its tier thresholds; the
/// result is clamped to 0..100. Both the thresholds and the penalty weights are editable in
/// Settings.
class HealthScoringConfig {
  const HealthScoringConfig({
    this.cpu = const MetricTiers(50, 75, 90, 5, 15, 30),
    this.mem = const MetricTiers(70, 80, 90, 5, 12, 25),
    this.disk = const MetricTiers(80, 90, 95, 10, 25, 30),
    this.latency = const MetricTiers(50, 100, 200, 3, 7, 15),
  });

  final MetricTiers cpu;
  final MetricTiers mem;
  final MetricTiers disk;
  final MetricTiers latency;

  static const defaults = HealthScoringConfig();

  /// Where the encoded config lives in `app_settings`.
  ///
  /// On the config rather than on the Settings screen's view model: the telemetry poller reads it
  /// every cycle to score each host, and two spellings of the same key would leave the poller
  /// scoring with the defaults while the user's own thresholds sat in the database.
  static const settingKey = 'health_scoring';

  int score(double cpuPct, double ramPct, double diskPct, int rtt) =>
      (100 -
              cpu.penaltyFor(cpuPct) -
              mem.penaltyFor(ramPct) -
              disk.penaltyFor(diskPct) -
              latency.penaltyFor(rtt.toDouble()))
          .clamp(0, 100);

  /// Build a human-readable breakdown of the score for the given readings.
  HealthBreakdown breakdown(
    double cpuPct,
    double ramPct,
    double diskPct,
    int rtt, {
    required bool online,
  }) {
    if (!online) {
      return const HealthBreakdown(
        0,
        offline: true,
        factors: [HealthFactor('Host offline or unreachable — score forced to 0', 100)],
      );
    }

    final factors = <HealthFactor>[];
    void consider(String name, double value, String unit, MetricTiers tiers) {
      final pen = tiers.penaltyFor(value);
      if (pen <= 0) return;
      final lvl = tiers.tierLabel(value) ?? '';
      final thr = tiers.tierThreshold(value)?.round() ?? 0;
      factors.add(HealthFactor('$name ${value.round()}$unit — $lvl (≥$thr$unit)', pen));
    }

    consider('CPU', cpuPct, '%', cpu);
    consider('Memory', ramPct, '%', mem);
    consider('Disk', diskPct, '%', disk);
    consider('Latency', rtt.toDouble(), 'ms', latency);

    final total = factors.fold<int>(0, (a, f) => a + f.penalty);
    return HealthBreakdown((100 - total).clamp(0, 100), offline: false, factors: factors);
  }

  /// Compact "cpu:50,75,90,5,15,30;mem:...;disk:...;lat:..." encoding for `app_settings` storage.
  ///
  /// Kotlin renders a `Float` as "50.0", and Dart renders the equivalent `double` identically, so
  /// the strings written by the two implementations match byte for byte.
  String encode() => [('cpu', cpu), ('mem', mem), ('disk', disk), ('lat', latency)]
      .map(
        (e) =>
            '${e.$1}:${e.$2.warnAt},${e.$2.highAt},${e.$2.criticalAt},'
            '${e.$2.warnPenalty},${e.$2.highPenalty},${e.$2.criticalPenalty}',
      )
      .join(';');

  HealthScoringConfig copyWith({
    MetricTiers? cpu,
    MetricTiers? mem,
    MetricTiers? disk,
    MetricTiers? latency,
  }) => HealthScoringConfig(
    cpu: cpu ?? this.cpu,
    mem: mem ?? this.mem,
    disk: disk ?? this.disk,
    latency: latency ?? this.latency,
  );

  @override
  bool operator ==(Object other) =>
      other is HealthScoringConfig &&
      other.cpu == cpu &&
      other.mem == mem &&
      other.disk == disk &&
      other.latency == latency;

  @override
  int get hashCode => Object.hash(cpu, mem, disk, latency);

  /// Decodes [encode]'s format, falling back to the defaults for anything unparseable.
  ///
  /// The Kotlin original wraps the whole parse in a `try/catch` returning DEFAULT: a corrupt
  /// settings row must never stop the app from scoring hosts. Per-entry failures likewise fall back
  /// to that metric's default rather than dropping the whole config.
  static HealthScoringConfig decode(String? s) {
    if (s == null || s.trim().isEmpty) return defaults;
    try {
      final map = <String, MetricTiers>{};
      for (final part in s.split(';')) {
        final kv = part.split(':');
        if (kv.length < 2) continue;
        // Only the first ':' separates key from value (Kotlin used limit = 2).
        final value = kv.sublist(1).join(':');
        final n = value.split(',').map((e) => e.trim()).toList();
        if (n.length < 6) continue;
        final warnAt = double.tryParse(n[0]);
        final highAt = double.tryParse(n[1]);
        final criticalAt = double.tryParse(n[2]);
        final warnPenalty = int.tryParse(n[3]);
        final highPenalty = int.tryParse(n[4]);
        final criticalPenalty = int.tryParse(n[5]);
        if (warnAt == null ||
            highAt == null ||
            criticalAt == null ||
            warnPenalty == null ||
            highPenalty == null ||
            criticalPenalty == null) {
          // Kotlin's toFloat()/toInt() throw here, and the catch discards the *entire* config.
          return defaults;
        }
        map[kv[0]] = MetricTiers(
          warnAt,
          highAt,
          criticalAt,
          warnPenalty,
          highPenalty,
          criticalPenalty,
        );
      }
      return HealthScoringConfig(
        cpu: map['cpu'] ?? defaults.cpu,
        mem: map['mem'] ?? defaults.mem,
        disk: map['disk'] ?? defaults.disk,
        latency: map['lat'] ?? defaults.latency,
      );
    } catch (_) {
      return defaults;
    }
  }
}
