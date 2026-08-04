import 'package:flutter/foundation.dart';

import '../../domain/health_scoring.dart';
import '../../domain/health_tier_form.dart';
import 'app_state.dart';

/// The Health Scoring tool's state, split out of `HealthScoringToolView` in `ui/ToolsScreen.kt`.
///
/// The editor holds its own draft of the twenty-four fields, separate from the saved config, so a
/// half-typed value never becomes the live scoring rule — every host's score would shift under the
/// user as they typed.
class HealthScoringViewModel extends ChangeNotifier {
  HealthScoringViewModel(this._app);

  final AppState _app;

  /// Where the encoded config lives in `app_settings`.
  static const settingKey = 'health_scoring';

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  HealthScoringConfig _saved = HealthScoringConfig.defaults;
  late Map<HealthMetric, TierFields> _draft = fieldsFrom(_saved);

  /// The configuration currently scoring hosts.
  HealthScoringConfig get saved => _saved;

  /// The editor's working copy.
  Map<HealthMetric, TierFields> get draft => Map.unmodifiable(_draft);

  String? _status;

  String? get status => _status;

  void dismissStatus() {
    _status = null;
    notifyListeners();
  }

  Future<void> start() async {
    _saved = HealthScoringConfig.decode(await _app.repository.getSetting(settingKey));
    _draft = fieldsFrom(_saved);
    _safeNotify();
  }

  /// Records a typed value. Deliberately does not validate on every keystroke — an error under a
  /// field the user is halfway through typing is noise.
  void edit(HealthMetric metric, void Function(TierFields fields) change) {
    final fields = _draft[metric];
    if (fields == null) return;
    change(fields);
    notifyListeners();
  }

  /// The first problem with the draft, or null when it can be saved.
  String? get validationError => validateAll(_draft);

  bool get canSave => validationError == null && isDirty;

  /// True when the draft differs from what is saved.
  bool get isDirty {
    final candidate = configFrom(_draft);
    return candidate == null || candidate != _saved;
  }

  /// A preview of what the draft would score for a given set of readings.
  ///
  /// Shown live because the numbers in this form are abstract until you see what they do — "warn at
  /// 50" means nothing next to "a host at 60% CPU now scores 95".
  HealthBreakdown? previewFor({
    required double cpuPercent,
    required double memoryPercent,
    required double diskPercent,
    required int latencyMs,
  }) {
    final candidate = configFrom(_draft);
    if (candidate == null) return null;
    return candidate.breakdown(cpuPercent, memoryPercent, diskPercent, latencyMs, online: true);
  }

  /// Persists the draft. Returns null on success, otherwise the reason.
  Future<String?> save() async {
    final error = validationError;
    if (error != null) return error;
    final candidate = configFrom(_draft);
    if (candidate == null) return 'Those values cannot be used.';

    await _app.repository.insertSetting(settingKey, candidate.encode());
    _saved = candidate;
    // Re-seeded from the saved config so the fields show exactly what was stored — including any
    // normalisation, which would otherwise leave the form disagreeing with the rule it just wrote.
    _draft = fieldsFrom(candidate);
    _status = 'Saved. Scores update on the next telemetry poll.';
    _safeNotify();
    return null;
  }

  /// Throws the draft away and shows what is saved.
  void revert() {
    _draft = fieldsFrom(_saved);
    _status = null;
    notifyListeners();
  }

  /// Restores the shipped defaults and saves them.
  Future<void> resetToDefaults() async {
    await _app.repository.insertSetting(settingKey, HealthScoringConfig.defaults.encode());
    _saved = HealthScoringConfig.defaults;
    _draft = fieldsFrom(_saved);
    _status = 'Reset to the default thresholds.';
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
