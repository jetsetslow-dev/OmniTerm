import 'package:flutter/foundation.dart';

/// The slice of app state the root scaffold needs.
///
/// This is a deliberately small seam carved out of the legacy 12,310-line `AppViewModel`: the
/// scaffold only ever read a handful of its properties (alert count, keep-screen-on, refresh
/// state, monetization gating). Feature ViewModels land alongside it as their screens are ported
/// — see MIGRATION.md §5.2.
class ShellState extends ChangeNotifier {
  ShellState({this.keepScreenOnSetter});

  final Future<void> Function(bool enabled)? keepScreenOnSetter;
  bool _isRefreshing = false;
  bool _isKeepScreenOnEnabled = false;
  bool _showKeepScreenOnWarning = false;
  bool _showAlertsPopup = false;
  int _visibleAlertCount = 0;

  // Monetization gating. Nothing monetization-related is shown while Billing is still resolving,
  // so a paying user never flashes the free-tier UI.
  bool _licenseResolved = false;
  bool _licenseEnabled = false;
  bool _unlocked = false;
  bool _adsRemoved = false;
  bool _hostLimitReconciliationRequired = false;
  String _hostLimitReconciliationReason = '';

  bool get isRefreshing => _isRefreshing;
  bool get isKeepScreenOnEnabled => _isKeepScreenOnEnabled;
  bool get showKeepScreenOnWarning => _showKeepScreenOnWarning;
  bool get showAlertsPopup => _showAlertsPopup;

  /// Unacknowledged, unmuted alerts — 0 while alerts are disabled.
  int get visibleAlertCount => _visibleAlertCount;

  bool get _showMonetizationUi => _licenseEnabled && _licenseResolved;
  bool get showFreePlanBanner => _showMonetizationUi && !_unlocked;
  bool get showAdBanner => _showMonetizationUi && !_adsRemoved;
  bool get hostLimitReconciliationRequired => _hostLimitReconciliationRequired;
  String get hostLimitReconciliationReason => _hostLimitReconciliationReason;

  void openAlertsPopup() {
    if (_showAlertsPopup) return;
    _showAlertsPopup = true;
    notifyListeners();
  }

  void closeAlertsPopup() {
    if (!_showAlertsPopup) return;
    _showAlertsPopup = false;
    notifyListeners();
  }

  void requestKeepScreenOnToggle() {
    if (_isKeepScreenOnEnabled) {
      _applyKeepScreenOn(false);
      return;
    }
    _showKeepScreenOnWarning = true;
    notifyListeners();
  }

  void confirmKeepScreenOn() {
    _showKeepScreenOnWarning = false;
    _applyKeepScreenOn(true);
  }

  void cancelKeepScreenOnWarning() {
    if (!_showKeepScreenOnWarning) return;
    _showKeepScreenOnWarning = false;
    notifyListeners();
  }

  void setKeepScreenOnDirect(bool enabled) => _applyKeepScreenOn(enabled);

  void _applyKeepScreenOn(bool enabled) {
    if (_isKeepScreenOnEnabled == enabled) return;
    _isKeepScreenOnEnabled = enabled;
    keepScreenOnSetter?.call(enabled);
    notifyListeners();
  }

  /// Mirrors `viewModel.updateLicenseEntitlement(...)`, which the legacy scaffold drove from the
  /// billing controller's state. [enabled] is false in the openSource flavor, where no billing
  /// client exists at all.
  void updateLicenseEntitlement({
    required bool enabled,
    required bool resolved,
    required bool unlocked,
    required bool adsRemoved,
  }) {
    if (_licenseEnabled == enabled &&
        _licenseResolved == resolved &&
        _unlocked == unlocked &&
        _adsRemoved == adsRemoved) {
      return;
    }
    _licenseEnabled = enabled;
    _licenseResolved = resolved;
    _unlocked = unlocked;
    _adsRemoved = adsRemoved;
    if (!enabled || unlocked) {
      _hostLimitReconciliationRequired = false;
      _hostLimitReconciliationReason = '';
    }
    notifyListeners();
  }

  void reconcileHostLimit(int hostCount, {String? reason}) {
    final required =
        _licenseEnabled && _licenseResolved && !_unlocked && hostCount > 1;
    final nextReason = required
        ? (reason ?? 'The free Play Store build supports one saved host.')
        : '';
    if (_hostLimitReconciliationRequired == required &&
        _hostLimitReconciliationReason == nextReason) {
      return;
    }
    _hostLimitReconciliationRequired = required;
    _hostLimitReconciliationReason = nextReason;
    notifyListeners();
  }

  void completeHostLimitReconciliation() {
    if (!_hostLimitReconciliationRequired) return;
    _hostLimitReconciliationRequired = false;
    _hostLimitReconciliationReason = '';
    notifyListeners();
  }

  /// Unacknowledged, unmuted alert count, recomputed by the alerts pipeline.
  void updateVisibleAlertCount(int count) {
    if (_visibleAlertCount == count) return;
    _visibleAlertCount = count;
    notifyListeners();
  }

  Future<void> refreshCurrentScreen([Future<void> Function()? refresh]) async {
    if (_isRefreshing || refresh == null) return;
    _isRefreshing = true;
    notifyListeners();
    try {
      await refresh();
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }
}
