import 'package:flutter/foundation.dart';

/// The slice of app state the root scaffold needs.
///
/// This is a deliberately small seam carved out of the legacy 12,310-line `AppViewModel`: the
/// scaffold only ever read a handful of its properties (alert count, keep-screen-on, refresh
/// state, monetization gating). Feature ViewModels land alongside it as their screens are ported
/// — see MIGRATION.md §5.2.
class ShellState extends ChangeNotifier {
  bool _isRefreshing = false;
  bool _isKeepScreenOnEnabled = false;
  bool _showAlertsPopup = false;
  int _visibleAlertCount = 0;

  // Monetization gating. Nothing monetization-related is shown while Billing is still resolving,
  // so a paying user never flashes the free-tier UI.
  bool _licenseResolved = false;
  bool _licenseEnabled = false;
  bool _unlocked = false;
  bool _adsRemoved = false;

  bool get isRefreshing => _isRefreshing;
  bool get isKeepScreenOnEnabled => _isKeepScreenOnEnabled;
  bool get showAlertsPopup => _showAlertsPopup;

  /// Unacknowledged, unmuted alerts — 0 while alerts are disabled.
  int get visibleAlertCount => _visibleAlertCount;

  bool get _showMonetizationUi => _licenseEnabled && _licenseResolved;
  bool get showFreePlanBanner => _showMonetizationUi && !_unlocked;
  bool get showAdBanner => _showMonetizationUi && !_adsRemoved;

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
    // TODO(migration): the legacy path warns before enabling on low battery, then drives
    // wakelock_plus. Ported with SessionService (MIGRATION.md §3.1).
    _isKeepScreenOnEnabled = !_isKeepScreenOnEnabled;
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
    notifyListeners();
  }

  /// Unacknowledged, unmuted alert count, recomputed by the alerts pipeline.
  void updateVisibleAlertCount(int count) {
    if (_visibleAlertCount == count) return;
    _visibleAlertCount = count;
    notifyListeners();
  }

  Future<void> refreshCurrentScreen() async {
    // TODO(migration): dispatches to the active screen's reload once the feature ViewModels exist.
    _isRefreshing = true;
    notifyListeners();
    _isRefreshing = false;
    notifyListeners();
  }
}
