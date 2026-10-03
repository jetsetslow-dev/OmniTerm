/// The default alert rules the app seeds on demand, ported from `DEFAULT_ALERT_RULE_PRESETS` in
/// `ui/AppViewModel.kt`.
///
/// Each carries a stable [AlertPreset.presetKey] for the same reason the script presets do: the
/// toggle must remove exactly what it seeded, and a backup must tell a pristine default (skip it)
/// from one the user retuned (keep it). The keys are historical facts about databases already on
/// devices — see `legacy_presets.dart`, which back-stamps them onto rows seeded before the column
/// existed.
library;

class AlertPreset {
  const AlertPreset({
    required this.presetKey,
    required this.metricName,
    required this.thresholdValue,
    required this.severity,
  });

  final String presetKey;
  final String metricName;
  final double thresholdValue;
  final String severity;
}

/// The `app_settings` key holding whether the default rules are enabled.
const alertPresetsSetting = 'alert_presets';

/// Seeded fleet-wide (`serverId = 0`), so one rule covers every host rather than needing a copy per
/// machine — which would silently miss any host added later.
const kAlertPresets = <AlertPreset>[
  AlertPreset(
    presetKey: 'alert.cpu',
    metricName: 'CPU Usage',
    thresholdValue: 90,
    severity: 'CRITICAL',
  ),
  AlertPreset(
    presetKey: 'alert.memory',
    metricName: 'Memory Usage',
    thresholdValue: 90,
    severity: 'CRITICAL',
  ),
  AlertPreset(
    presetKey: 'alert.disk',
    metricName: 'Disk Usage',
    thresholdValue: 90,
    // A warning, not critical: a full disk is serious, but 90% full is a trend to act on rather
    // than an outage in progress.
    severity: 'WARNING',
  ),
  AlertPreset(
    presetKey: 'alert.latency',
    metricName: 'Latency',
    thresholdValue: 250,
    severity: 'WARNING',
  ),
  AlertPreset(
    presetKey: 'alert.temperature',
    metricName: 'Temperature',
    thresholdValue: 80,
    severity: 'WARNING',
  ),
];

/// True when a stored rule still matches what its preset seeded.
///
/// Matched on threshold and severity, the two fields a user actually retunes. Once either differs
/// the rule is theirs, and both a backup and a "disable defaults" must leave it alone.
bool isPristineAlertPreset(AlertPreset preset, double threshold, String severity) =>
    preset.thresholdValue == threshold && preset.severity == severity;
