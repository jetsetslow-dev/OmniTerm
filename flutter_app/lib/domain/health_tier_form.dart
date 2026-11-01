/// Validation for the health-scoring editor's twenty-four number fields.
///
/// Separated from the widget because a bad configuration here is not a cosmetic problem: thresholds
/// that do not ascend make a tier unreachable, so a metric silently stops contributing to the score
/// and a host that is in trouble keeps reporting 100.
library;

import 'health_scoring.dart';
import 'input_validation.dart';

/// Which metric a set of tiers belongs to.
enum HealthMetric {
  cpu('CPU', '%'),
  memory('Memory', '%'),
  disk('Disk', '%'),
  latency('Latency', 'ms');

  const HealthMetric(this.label, this.unit);

  final String label;
  final String unit;

  /// Latency is measured in milliseconds and has no natural ceiling; the other three are
  /// percentages and cannot exceed 100.
  bool get isPercent => unit == '%';
}

/// The six editable fields of one metric, held as the raw text the user typed.
///
/// Text rather than numbers because a half-typed value ("9" on the way to "90") must not be
/// rejected mid-keystroke, and clearing a field must not silently substitute a zero.
class TierFields {
  TierFields({
    required this.warnAt,
    required this.highAt,
    required this.criticalAt,
    required this.warnPenalty,
    required this.highPenalty,
    required this.criticalPenalty,
  });

  TierFields.fromTiers(MetricTiers tiers)
    : warnAt = _number(tiers.warnAt),
      highAt = _number(tiers.highAt),
      criticalAt = _number(tiers.criticalAt),
      warnPenalty = '${tiers.warnPenalty}',
      highPenalty = '${tiers.highPenalty}',
      criticalPenalty = '${tiers.criticalPenalty}';

  String warnAt;
  String highAt;
  String criticalAt;
  String warnPenalty;
  String highPenalty;
  String criticalPenalty;

  /// Renders a threshold without a trailing `.0`, since every real value is a whole number and
  /// "50.0" in a text field invites someone to type over the decimal point.
  static String _number(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  /// The tiers these fields describe, as Kotlin's `TierFields.toTiers`: a value that does not
  /// parse falls back to [fallback]'s (a penalty such as "5.5" passes validation but is not a whole
  /// number, so Kotlin keeps the default for it).
  MetricTiers toTiers(MetricTiers fallback) => MetricTiers(
    double.tryParse(warnAt.trim()) ?? fallback.warnAt,
    double.tryParse(highAt.trim()) ?? fallback.highAt,
    double.tryParse(criticalAt.trim()) ?? fallback.criticalAt,
    int.tryParse(warnPenalty.trim()) ?? fallback.warnPenalty,
    int.tryParse(highPenalty.trim()) ?? fallback.highPenalty,
    int.tryParse(criticalPenalty.trim()) ?? fallback.criticalPenalty,
  );
}

/// Per-field errors for one metric, ported from Kotlin's `TierErrors`.
///
/// Thresholds for percentage metrics are capped at 100; latency is whole milliseconds. Penalties
/// are points off a 100-point score. Tiers must ascend or the higher ones are unreachable.
class TierErrors {
  TierErrors(TierFields f, HealthMetric metric)
    : warn = _threshold(f.warnAt, metric),
      high = _threshold(f.highAt, metric),
      crit = _threshold(f.criticalAt, metric),
      warnPen = percentError(f.warnPenalty),
      highPen = percentError(f.highPenalty),
      critPen = percentError(f.criticalPenalty),
      order = _order(f);

  final String? warn;
  final String? high;
  final String? crit;
  final String? warnPen;
  final String? highPen;
  final String? critPen;

  /// Non-null when the three thresholds are individually valid but out of order.
  final String? order;

  String? get firstError => warn ?? high ?? crit ?? warnPen ?? highPen ?? critPen ?? order;

  static String? _threshold(String text, HealthMetric metric) =>
      metric.isPercent ? percentError(text) : countError(text, min: 1, max: 600000);

  static String? _order(TierFields f) {
    final w = double.tryParse(f.warnAt.trim());
    final h = double.tryParse(f.highAt.trim());
    final c = double.tryParse(f.criticalAt.trim());
    if (w == null || h == null || c == null) return null;
    return w > h || h > c ? 'Thresholds must increase: warn <= high <= crit' : null;
  }
}

/// The first problem with a metric's fields, or null when they are usable.
String? validateTier(TierFields fields, HealthMetric metric) =>
    TierErrors(fields, metric).firstError;

/// The first problem across all four metrics, or null when the whole form is usable.
String? validateAll(Map<HealthMetric, TierFields> fields) {
  for (final metric in HealthMetric.values) {
    final tier = fields[metric];
    if (tier == null) continue;
    final error = validateTier(tier, metric);
    if (error != null) return '${metric.label} — $error';
  }
  return null;
}

/// Builds a config from a validated form, or null when anything is unusable.
HealthScoringConfig? configFrom(Map<HealthMetric, TierFields> fields) {
  if (validateAll(fields) != null) return null;
  const d = HealthScoringConfig.defaults;
  final cpu = fields[HealthMetric.cpu]?.toTiers(d.cpu);
  final memory = fields[HealthMetric.memory]?.toTiers(d.mem);
  final disk = fields[HealthMetric.disk]?.toTiers(d.disk);
  final latency = fields[HealthMetric.latency]?.toTiers(d.latency);
  if (cpu == null || memory == null || disk == null || latency == null) return null;
  return HealthScoringConfig(cpu: cpu, mem: memory, disk: disk, latency: latency);
}

/// Splits a config back into editable fields.
Map<HealthMetric, TierFields> fieldsFrom(HealthScoringConfig config) => {
  HealthMetric.cpu: TierFields.fromTiers(config.cpu),
  HealthMetric.memory: TierFields.fromTiers(config.mem),
  HealthMetric.disk: TierFields.fromTiers(config.disk),
  HealthMetric.latency: TierFields.fromTiers(config.latency),
};
