import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import '../ui/shell_state.dart';
import '../ui/view_model/app_state.dart';
import '../ui/view_model/host_status_probe.dart';
import '../ui/view_model/shell_view_model.dart';
import '../ui/view_model/telemetry_poller.dart';
import 'battery_saver_notifications.dart';

enum DevicePowerState { charging, full, discharging, unknown }

abstract interface class BatteryMonitor {
  Stream<DevicePowerState> get states;
  Future<int> level();
}

class PlatformBatteryMonitor implements BatteryMonitor {
  PlatformBatteryMonitor({Battery? battery}) : _battery = battery ?? Battery();

  final Battery _battery;

  @override
  Stream<DevicePowerState> get states => _battery.onBatteryStateChanged.map(
    (state) => switch (state) {
      BatteryState.charging => DevicePowerState.charging,
      BatteryState.full => DevicePowerState.full,
      BatteryState.discharging => DevicePowerState.discharging,
      _ => DevicePowerState.unknown,
    },
  );

  @override
  Future<int> level() => _battery.batteryLevel;
}

/// Sheds polling, wakelock and persistent SSH clients when an unplugged device reaches the user's
/// threshold, and resumes with five percentage points of hysteresis.
class BatterySaverController extends ChangeNotifier {
  BatterySaverController(
    this._app,
    this._shell,
    this._poller,
    this._hostProbe,
    this._terminals, {
    BatteryMonitor? monitor,
    this._notifier,
  }) : _monitor = monitor ?? PlatformBatteryMonitor() {
    _app.addListener(_onPreferencesChanged);
  }

  final AppState _app;
  final ShellState _shell;
  final TelemetryPoller _poller;
  final HostStatusProbe _hostProbe;
  final ShellViewModel _terminals;
  final BatteryMonitor _monitor;
  final BatterySaverNotifier? _notifier;

  StreamSubscription<DevicePowerState>? _subscription;
  DevicePowerState _powerState = DevicePowerState.unknown;
  bool _active = false;
  bool _showDialog = false;
  int _engagedAtPercent = 0;
  bool _disposed = false;
  bool _manualResumeUntilRecovery = false;
  int _evaluationGeneration = 0;
  bool? _lastEnabled;
  int? _lastThreshold;

  bool get active => _active;
  bool get showDialog => _showDialog;
  int get engagedAtPercent => _engagedAtPercent;
  int get thresholdPercent => _app.preferences.batterySaverThresholdPercent;

  void start() {
    _subscription ??= _monitor.states.listen((state) {
      _powerState = state;
      _scheduleEvaluation();
    });
    _scheduleEvaluation();
  }

  void _onPreferencesChanged() {
    final enabled = _app.preferences.batterySaverEnabled;
    final threshold = _app.preferences.batterySaverThresholdPercent;
    if (_lastEnabled == enabled && _lastThreshold == threshold) return;
    _lastEnabled = enabled;
    _lastThreshold = threshold;
    if (!enabled) {
      _evaluationGeneration++;
      _manualResumeUntilRecovery = false;
      _resume();
    } else {
      _scheduleEvaluation();
    }
  }

  void _scheduleEvaluation() {
    final generation = ++_evaluationGeneration;
    unawaited(_evaluate(generation));
  }

  Future<void> _evaluate(int generation) async {
    // AppState starts with product defaults while its database read is in flight. Acting on those
    // defaults can park terminals for a user who has battery saver disabled.
    if (_disposed || !_app.settingsLoaded || !_app.preferences.batterySaverEnabled) {
      return;
    }
    try {
      final percent = await _monitor.level();
      if (_disposed ||
          generation != _evaluationGeneration ||
          !_app.settingsLoaded ||
          !_app.preferences.batterySaverEnabled) {
        return;
      }
      final charging =
          _powerState == DevicePowerState.charging || _powerState == DevicePowerState.full;
      final recovered = charging || percent >= thresholdPercent + 5;
      if (recovered) {
        _manualResumeUntilRecovery = false;
        if (_showDialog && !_active) {
          _showDialog = false;
          unawaited(_notifier?.cancel());
          notifyListeners();
        }
      }
      if (_active) {
        if (recovered) _resume();
      } else if (!_showDialog &&
          !_manualResumeUntilRecovery &&
          !charging &&
          percent <= thresholdPercent) {
        _requestEngagement(percent);
      }
    } catch (_) {
      // A device without a battery simply never engages the saver.
    }
  }

  void _requestEngagement(int percent) {
    if (_active || _showDialog) return;
    _showDialog = true;
    _engagedAtPercent = percent;
    unawaited(_notifier?.showPrompt(percent: percent));
    notifyListeners();
  }

  /// Applies the power-saving actions only after the user accepts the low-battery prompt.
  void confirm() {
    if (!_showDialog || _active || !_app.preferences.batterySaverEnabled) {
      return;
    }
    _active = true;
    _showDialog = false;
    _shell.setKeepScreenOnDirect(false);
    _poller.stop();
    _hostProbe.stop();
    _terminals.leaveOrBackgroundAll();
    unawaited(_notifier?.showActive(percent: _engagedAtPercent));
    notifyListeners();
  }

  void dismissDialog() {
    if (!_showDialog) return;
    _manualResumeUntilRecovery = true;
    _showDialog = false;
    unawaited(_notifier?.cancel());
    notifyListeners();
  }

  void resume() {
    _evaluationGeneration++;
    _manualResumeUntilRecovery = true;
    _resume();
  }

  void _resume() {
    if (!_active && !_showDialog) return;
    final wasActive = _active;
    _active = false;
    _showDialog = false;
    unawaited(_notifier?.cancel());
    if (wasActive) {
      _hostProbe.start();
      _poller.start();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _evaluationGeneration++;
    _app.removeListener(_onPreferencesChanged);
    _subscription?.cancel();
    super.dispose();
  }
}
