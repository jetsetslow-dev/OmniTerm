/// Validation for the health-scoring editor's twenty-four number fields.
///
/// Separated from the widget because a bad configuration here is not a cosmetic problem: thresholds
/// that do not ascend make a tier unreachable, so a metric silently stops contributing to the score
/// and a host that is in trouble keeps reporting 100.
library;

import 'health_scoring.dart';

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

  /// The tiers these fields describe, or null when any of them is unusable.
  MetricTiers? toTiers() {
    final warn = double.tryParse(warnAt.trim());
    final high = double.tryParse(highAt.trim());
    final critical = double.tryParse(criticalAt.trim());
    final warnPen = int.tryParse(warnPenalty.trim());
    final highPen = int.tryParse(highPenalty.trim());
    final criticalPen = int.tryParse(criticalPenalty.trim());
    if (warn == null ||
        high == null ||
        critical == null ||
        warnPen == null ||
        highPen == null ||
        criticalPen == null) {
      return null;
    }
    return MetricTiers(warn, high, critical, warnPen, highPen, criticalPen);
  }
}

/// The first problem with a metric's fields, or null when they are usable.
///
/// One message at a time, in reading order, because six simultaneous errors under a form is noise
/// rather than guidance.
String? validateTier(TierFields fields, HealthMetric metric) {
  final thresholdError = metric.isPercent
      ? _percentError
      : (String text) => _countError(text, min: 1, max: 600000);

  for (final (value, name) in [
    (fields.warnAt, 'Warn threshold'),
    (fields.highAt, 'High threshold'),
    (fields.criticalAt, 'Critical threshold'),
  ]) {
    final error = thresholdError(value);
    if (error != null) return '$name: $error';
  }

  for (final (value, name) in [
    (fields.warnPenalty, 'Warn penalty'),
    (fields.highPenalty, 'High penalty'),
    (fields.criticalPenalty, 'Critical penalty'),
  ]) {
    // A penalty is a number of points off a score that starts at 100, so it is bounded the same way.
    final error = _percentError(value);
    if (error != null) return '$name: $error';
  }

  final warn = double.tryParse(fields.warnAt.trim());
  final high = double.tryParse(fields.highAt.trim());
  final critical = double.tryParse(fields.criticalAt.trim());
  if (warn != null && high != null && critical != null && (warn > high || high > critical)) {
    // Out-of-order thresholds make the middle tier unreachable, so the metric quietly stops
    // deducting anything and a struggling host keeps scoring 100.
    return 'Thresholds must increase: warn ≤ high ≤ critical';
  }

  return null;
}

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
  final cpu = fields[HealthMetric.cpu]?.toTiers();
  final memory = fields[HealthMetric.memory]?.toTiers();
  final disk = fields[HealthMetric.disk]?.toTiers();
  final latency = fields[HealthMetric.latency]?.toTiers();
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

String? _percentError(String text) => _countError(text, min: 0, max: 100);

String? _countError(String text, {required int min, required int max}) {
  final trimmed = text.trim();
  // An empty field is its own message: "must be a number" reads as though what was typed was wrong.
  if (trimmed.isEmpty) return 'required';
  final value = double.tryParse(trimmed);
  if (value == null) return 'must be a number';
  if (value.isNaN || value.isInfinite) return 'must be a number';
  if (value < min || value > max) return 'must be between $min and $max';
  return null;
}
