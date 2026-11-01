import 'measurement_units.dart';

/// What a fired alert says when it appears in the notification shade.
///
/// Kept as a pure value with its own builder, per convention 3: the wording is the whole point of
/// the notification — a user is being interrupted, possibly while asleep — and it is not something
/// that should only be checkable by firing a real alert on a real device.
class AlertNotification {
  const AlertNotification({required this.id, required this.title, required this.body});

  final int id;
  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is AlertNotification && other.id == id && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(id, title, body);

  @override
  String toString() => 'AlertNotification($id, "$title", "$body")';
}

/// A stable id for one rule/host pair.
///
/// Computed here rather than with `String.hashCode`, which the Dart VM is free to seed differently
/// between runs. The id has to survive a restart: it is how a resolved alert's notification gets
/// cancelled, and an unstable id would leave a stale "CPU at 97%" banner in the shade for a host
/// that recovered hours ago.
///
/// Java's 31-based string hash, masked to a positive 31-bit int because the platform APIs take a
/// signed int and a negative id is a needless portability risk.
int alertNotificationId(int ruleId, int serverId) {
  var hash = 0;
  for (final unit in 'alert_${ruleId}_$serverId'.codeUnits) {
    hash = (31 * hash + unit) & 0x7FFFFFFF;
  }
  return hash;
}

/// Build the shade entry for a fired alert.
///
/// [metricName], [severity] and [mountPoint] come from the rule; [value] and [threshold] are always
/// in the *stored* units (Celsius for temperature), and are converted for display here so the
/// notification agrees with every other screen.
AlertNotification buildAlertNotification({
  required int ruleId,
  required int serverId,
  required String serverName,
  required String severity,
  required String metricName,
  required String mountPoint,
  required double value,
  required double threshold,
  MeasurementSystem system = MeasurementSystem.metric,
}) {
  final isTemperature = metricName == 'Temperature';
  final unit = switch (metricName) {
    'Latency' => 'ms',
    'Temperature' => temperatureUnit(system),
    _ => '%',
  };
  final shownValue = isTemperature ? celsiusToDisplay(value, system) : value;
  final shownThreshold = isTemperature ? celsiusToDisplay(threshold, system) : threshold;

  // A disk rule without its mount point is ambiguous on any host with more than one filesystem —
  // "Disk Usage at 95%" does not say which disk to go and clear.
  final mountSuffix = metricName == 'Disk Usage' && mountPoint.trim().isNotEmpty
      ? ' on ${mountPoint.trim()}'
      : '';

  return AlertNotification(
    id: alertNotificationId(ruleId, serverId),
    // The host leads the title after the severity, because the first question on seeing an alert is
    // always "which machine?".
    title: '$severity: $serverName',
    // The threshold is included, not just the value: "94%" means nothing without knowing whether
    // the line was 90 or 50.
    body:
        '$metricName$mountSuffix at ${_round(shownValue)}$unit '
        '(threshold ${_round(shownThreshold)}$unit)',
  );
}

/// Whole numbers, matching the Kotlin's `%.0f`. A tenth of a percent is noise in a shade entry.
String _round(double value) => value.round().toString();
