/// Deciding whether an alert rule is breaching, ported from `evaluateAlertRules` in
/// `ui/AppViewModel.kt`.
///
/// Separated from the view model because this is where a monitoring tool earns or loses trust: a
/// rule that fires on noise gets muted and then ignored, and one that never fires is worse than not
/// existing. The sustained-window and hysteresis behaviour lives in `AlertBreachTracker`; this file
/// answers the narrower question of *what value* a rule is looking at, and whether it is over.
library;

import '../data/app_database.dart';
import '../data/remote_models.dart';

/// The metric names a rule can watch. Stored as text, so the strings are the contract.
const alertMetrics = ['CPU Usage', 'Memory Usage', 'Disk Usage', 'Latency', 'Temperature'];

/// The sustained-breach windows a rule can require.
const alertWindows = ['2m', '5m', '10m', '15m'];

const alertSeverities = ['WARNING', 'CRITICAL'];

/// One telemetry sample for a host, in the units the rules are written in.
class AlertSample {
  const AlertSample({
    this.cpuPercent = 0,
    this.memoryPercent = 0,
    this.diskPercent = 0,
    this.latencyMs = 0,
    this.mounts = const [],
    this.cpuTempC,
  });

  final double cpuPercent;
  final double memoryPercent;

  /// Aggregate root-filesystem usage, used only when per-mount data is unavailable.
  final double diskPercent;

  final int latencyMs;
  final List<DiskUsage> mounts;

  /// Null on a host with no thermal sensor — most VMs and containers.
  final double? cpuTempC;
}

/// The value [rule] is watching, or null when this host cannot report it.
///
/// **Null is not zero.** A host with no thermal sensor returns null for a temperature rule, and null
/// is treated as "not breaching" so the rule simply never fires there. Substituting 0 would make
/// every such host look permanently cool, which is the same outcome by accident rather than by
/// design — and would make a "below" style rule fire on every VM.
double? currentValueFor(AlertRule rule, AlertSample sample) {
  switch (rule.metricName) {
    case 'CPU Usage':
      return sample.cpuPercent;
    case 'Memory Usage':
      return sample.memoryPercent;
    case 'Disk Usage':
      // A disk rule watches its own mount when per-mount data exists. The aggregate figure is only
      // a fallback for the root mount — applying it to a rule about /srv would report the wrong
      // filesystem's usage under that rule's name.
      final mount = sample.mounts.where((m) => m.mount == rule.mountPoint).firstOrNull;
      if (mount != null) return mount.percent;
      final isRoot = rule.mountPoint.isEmpty || rule.mountPoint == '/';
      return isRoot ? sample.diskPercent : null;
    case 'Latency':
      return sample.latencyMs.toDouble();
    case 'Temperature':
      return sample.cpuTempC;
    default:
      return null;
  }
}

/// True when [rule] is currently over its threshold for [sample].
bool isOverThreshold(AlertRule rule, AlertSample sample) {
  final value = currentValueFor(rule, sample);
  return value != null && value > rule.thresholdValue;
}

/// The sustained window [window] in milliseconds ("5m" → 300000).
///
/// An unparseable value yields 0, which fires on the first breaching sample. That is the safer
/// direction for a monitoring tool: a rule that alerts too eagerly is noticed and fixed, whereas one
/// that silently never fires is not.
int triggerWindowMs(String window) {
  final trimmed = window.trim();
  final digits = trimmed.endsWith('m') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  return (int.tryParse(digits) ?? 0) * 60 * 1000;
}

/// How long a gap in sampling discards the accumulated breach window.
///
/// Three poll intervals, floored at 90 seconds. When the app is paused or the host is unreachable,
/// wall-clock time keeps passing but nothing was observed — counting it as breached would fire an
/// alert about a period nobody measured.
int staleGapMs(int telemetryIntervalMs) {
  final gap = telemetryIntervalMs * 3;
  return gap < 90000 ? 90000 : gap;
}

/// The unit a metric's value is displayed in.
String unitFor(String metricName) => switch (metricName) {
  'Latency' => 'ms',
  'Temperature' => '°',
  _ => '%',
};

/// A one-line description of what [rule] watches.
String describeRule(AlertRule rule) {
  final mount = rule.metricName == 'Disk Usage' && rule.mountPoint.isNotEmpty
      ? ' on ${rule.mountPoint}'
      : '';
  return '${rule.metricName}$mount above ${rule.thresholdValue.round()}'
      '${unitFor(rule.metricName)} for ${rule.triggerWindow}';
}

/// Whether editing a rule should invalidate its firing incident and breach timer.
///
/// Changing what a rule *watches* or when it fires makes the existing incident meaningless — it was
/// raised under different terms. Renaming its note does not. Getting this wrong in either direction
/// is bad: too eager and every edit clears a real incident; too lax and a rule reports a breach
/// against a threshold it no longer has.
bool ruleEditInvalidatesIncident(AlertRule before, AlertRule after) =>
    before.metricName != after.metricName ||
    before.mountPoint != after.mountPoint ||
    before.thresholdValue != after.thresholdValue ||
    before.severity != after.severity ||
    before.triggerWindow != after.triggerWindow ||
    before.serverId != after.serverId ||
    // A disabled rule must drop its incident, or it would keep showing one it can no longer
    // re-evaluate.
    before.enabled != after.enabled;
