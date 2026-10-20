import 'dart:async';

import 'package:flutter/foundation.dart';

/// The slice of app state the root scaffold needs.
///
/// This is a deliberately small seam carved out of the legacy 12,310-line `AppViewModel`: the
/// scaffold only ever read a handful of its properties (alert count, keep-screen-on, refresh
/// state, monetization gating). Feature ViewModels land alongside it as their screens are ported
/// so navigation and feature state stay independently testable.
class ShellState extends ChangeNotifier {
  ShellState({this.keepScreenOnSetter});

  final Future<void> Function(bool enabled)? keepScreenOnSetter;
  bool _isRefreshing = false;
  String? _refreshError;
  bool _isKeepScreenOnEnabled = false;
  bool _showKeepScreenOnWarning = false;
  bool _isSettingKeepScreenOn = false;
  bool _requestedKeepScreenOn = false;
  String? _keepScreenOnError;
  Future<void>? _keepScreenOnOperation;
  bool _disposed = false;
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

  /// What went wrong in the last pull-to-refresh, or null when it succeeded.
  ///
  /// A refresh used to await its work and then discard whatever it found, so a pull that ended with
  /// a host stuck on "Checking host…" told the user nothing at all. Mirrors Kotlin's
  /// `AppViewModel.manualRefreshError`.
  String? get refreshError => _refreshError;

  void dismissRefreshError() {
    if (_refreshError == null) return;
    _refreshError = null;
    notifyListeners();
  }

  bool get isKeepScreenOnEnabled => _isKeepScreenOnEnabled;
  bool get showKeepScreenOnWarning => _showKeepScreenOnWarning;
  bool get isSettingKeepScreenOn => _isSettingKeepScreenOn;
  String? get keepScreenOnError => _keepScreenOnError;
  bool get requestedKeepScreenOn => _requestedKeepScreenOn;
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
    if (_disposed || _isSettingKeepScreenOn) return;
    if (_isKeepScreenOnEnabled) {
      unawaited(setKeepScreenOnDirect(false));
      return;
    }
    _showKeepScreenOnWarning = true;
    notifyListeners();
  }

  void confirmKeepScreenOn() {
    if (_disposed || _isSettingKeepScreenOn) return;
    unawaited(setKeepScreenOnDirect(true));
  }

  void cancelKeepScreenOnWarning() {
    if (!_showKeepScreenOnWarning) return;
    _showKeepScreenOnWarning = false;
    notifyListeners();
  }

  /// Serializes platform writes, including a saved default or battery-saver change arriving while
  /// another write is pending. The displayed flag always reflects the last acknowledged write.
  Future<void> setKeepScreenOnDirect(bool enabled) {
    if (_disposed) return Future<void>.value();
    final hadFeedback = _showKeepScreenOnWarning || _keepScreenOnError != null;
    _requestedKeepScreenOn = enabled;
    _showKeepScreenOnWarning = false;
    _keepScreenOnError = null;
    if (_keepScreenOnOperation != null) {
      notifyListeners();
      return _keepScreenOnOperation!;
    }
    if (_isKeepScreenOnEnabled == enabled) {
      if (hadFeedback) notifyListeners();
      return Future<void>.value();
    }
    if (keepScreenOnSetter == null) {
      _isKeepScreenOnEnabled = enabled;
      notifyListeners();
      return Future<void>.value();
    }
    final completion = Completer<void>();
    _keepScreenOnOperation = completion.future;
    _isSettingKeepScreenOn = true;
    notifyListeners();
    unawaited(_applyKeepScreenOn(completion));
    return completion.future;
  }

  Future<void> _applyKeepScreenOn(Completer<void> completion) async {
    try {
      while (!_disposed && _requestedKeepScreenOn != _isKeepScreenOnEnabled) {
        final target = _requestedKeepScreenOn;
        try {
          await keepScreenOnSetter!(target);
          if (_disposed) break;
          _isKeepScreenOnEnabled = target;
        } catch (error) {
          if (_disposed) break;
          // A newer request may already match the acknowledged state. A failure of the
          // superseded request must not prevent applying that newer request.
          if (target != _requestedKeepScreenOn) continue;
          _keepScreenOnError = 'Could not ${target ? 'enable' : 'disable'} Keep screen on: $error';
          break;
        }
      }
    } finally {
      _keepScreenOnOperation = null;
      _isSettingKeepScreenOn = false;
      if (!_disposed) notifyListeners();
      completion.complete();
    }
  }

  void retryKeepScreenOn() {
    if (_keepScreenOnError == null || _isSettingKeepScreenOn) return;
    unawaited(setKeepScreenOnDirect(_requestedKeepScreenOn));
  }

  void dismissKeepScreenOnError() {
    if (_disposed || _keepScreenOnError == null) return;
    _keepScreenOnError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
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
    final required = _licenseEnabled && _licenseResolved && !_unlocked && hostCount > 1;
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

  /// Runs one pull-to-refresh. [refresh] returns a user-facing failure, or null when the refresh
  /// was clean; whatever it returns is what the banner shows.
  Future<void> refreshCurrentScreen([Future<String?> Function()? refresh]) async {
    if (_isRefreshing || refresh == null) return;
    _isRefreshing = true;
    _refreshError = null;
    notifyListeners();
    try {
      _refreshError = await refresh();
    } catch (error) {
      // A refresh that throws is still a refresh the user asked for and watched spin. Swallowing it
      // here is what made a failing pull indistinguishable from a successful one.
      _refreshError = 'Refresh failed: $error';
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }
}
