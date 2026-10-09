import 'package:flutter/foundation.dart';

import '../../domain/app_preferences.dart';
import '../../domain/host_display.dart';
import 'app_state.dart';

/// The Settings tool's state, split out of `SettingsToolView` in `ui/ToolsScreen.kt`.
///
/// Edits go into a draft and reach the database only on save, matching the Kotlin. That is not
/// merely a style choice: several of these values feed live timers and buffers, and applying them
/// per keystroke would restart the telemetry poller on the way from "1" to "15".
class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel(this._app);

  final AppState _app;

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  AppPreferences _saved = AppPreferences.defaults;
  AppPreferences _draft = AppPreferences.defaults;

  /// What is currently in effect.
  AppPreferences get saved => _saved;

  /// The editor's working copy.
  AppPreferences get draft => _draft;

  final Set<String> _invalidFields = {};
  bool get isDirty => _draft != _saved || _invalidFields.isNotEmpty;
  bool get isValid => _invalidFields.isEmpty;
  bool _isSaving = false;
  bool get isSaving => _isSaving;
  Future<void>? _pendingSave;
  int draftRevision = 0;

  void setFieldValidity(String field, bool valid) {
    if (valid) {
      _invalidFields.remove(field);
    } else {
      _invalidFields.add(field);
    }
    _safeNotify();
  }

  // PIN setup persists immediately, while all unrelated edits remain staged.
  void pinConfigured() {
    _saved = _saved.copyWith(appLockEnabled: true);
    _draft = _draft.copyWith(appLockEnabled: true, useBiometrics: false);
    _app.applyPreferences(_saved);
    _safeNotify();
  }

  /// Combinations that are legal but probably not intended.
  List<String> get warnings => _draft.warnings;

  String? _status;
  bool _started = false;

  String? get status => _status;

  void dismissStatus() {
    _status = null;
    notifyListeners();
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final rows = await _app.repository.getAllSettings();
    _saved = AppPreferences.decode({for (final row in rows) row.key: row.value});
    _draft = _saved;
    _applyImmediate(_saved);
    _app.applyPreferences(_saved);
    _safeNotify();
  }

  /// Updates the draft.
  void update(AppPreferences Function(AppPreferences current) change) {
    _draft = change(_draft);
    notifyListeners();
  }

  Future<void> save() => _pendingSave ??= _save().whenComplete(() => _pendingSave = null);

  Future<void> _save() async {
    if (!isValid) throw StateError('Correct the highlighted settings before saving.');
    final snapshot = _draft;
    _isSaving = true;
    _status = null;
    _safeNotify();
    try {
      await _app.repository.inTransaction(() async {
        for (final entry in snapshot.encode().entries) {
          await _app.repository.insertSetting(entry.key, entry.value);
        }
        await _app.repository.pruneAlertHistoryPerServer(snapshot.alertHistoryLimit);
      });
      _saved = snapshot;
      // Normalize displayed numeric drafts only after persistence, without discarding edits
      // made while that snapshot was being saved.
      if (_draft == snapshot) draftRevision++;
      _applyImmediate(snapshot);
      _app.applyPreferences(snapshot);
      _status = 'Settings saved.';
    } finally {
      _isSaving = false;
      _safeNotify();
    }
  }

  /// Throws the draft away.
  void revert() {
    _draft = _saved;
    _invalidFields.clear();
    draftRevision++;
    _status = null;
    notifyListeners();
  }

  /// Restores every preference this screen owns to its default, and saves.
  Future<void> resetToDefaults() async {
    _draft = AppPreferences.defaults;
    await save();
    _status = 'Settings reset to defaults.';
    _safeNotify();
  }

  /// Pushes the settings that other parts of the app read from a live singleton.
  ///
  /// `HostDisplay` is observed directly by every screen that renders an address, so it has to be
  /// told rather than waiting to be read again on the next rebuild.
  void _applyImmediate(AppPreferences preferences) {
    HostDisplay.instance.hideSensitiveInfo = preferences.hideSensitiveInfo;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
