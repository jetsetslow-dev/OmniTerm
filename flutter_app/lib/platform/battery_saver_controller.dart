import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import '../ui/shell_state.dart';
import '../ui/view_model/app_state.dart';
import '../ui/view_model/shell_view_model.dart';
import '../ui/view_model/telemetry_poller.dart';

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
    this._terminals, {
    BatteryMonitor? monitor,
  }) : _monitor = monitor ?? PlatformBatteryMonitor() {
    _app.addListener(_onPreferencesChanged);
  }

  final AppState _app;
  final ShellState _shell;
  final TelemetryPoller _poller;
  final ShellViewModel _terminals;
  final BatteryMonitor _monitor;

  StreamSubscription<DevicePowerState>? _subscription;
  DevicePowerState _powerState = DevicePowerState.unknown;
  bool _active = false;
  bool _showDialog = false;
  int _engagedAtPercent = 0;
  bool _disposed = false;

  bool get active => _active;
  bool get showDialog => _showDialog;
  int get engagedAtPercent => _engagedAtPercent;
  int get thresholdPercent => _app.preferences.batterySaverThresholdPercent;

  void start() {
    _subscription ??= _monitor.states.listen((state) {
      _powerState = state;
      unawaited(_evaluate());
    });
    unawaited(_evaluate());
  }

  void _onPreferencesChanged() {
    if (!_app.preferences.batterySaverEnabled && _active) {
      resume();
    } else {
      unawaited(_evaluate());
    }
  }

  Future<void> _evaluate() async {
    if (_disposed || !_app.preferences.batterySaverEnabled) return;
    try {
      final percent = await _monitor.level();
      if (_disposed) return;
      final charging =
          _powerState == DevicePowerState.charging || _powerState == DevicePowerState.full;
      if (_active) {
        if (charging || percent >= thresholdPercent + 5) resume();
      } else if (!charging && percent <= thresholdPercent) {
        _engage(percent);
      }
    } catch (_) {
      // A device without a battery simply never engages the saver.
    }
  }

  void _engage(int percent) {
    if (_active) return;
    _active = true;
    _showDialog = true;
    _engagedAtPercent = percent;
    _shell.setKeepScreenOnDirect(false);
    _poller.stop();
    _terminals.leaveOrBackgroundAll();
    notifyListeners();
  }

  void dismissDialog() {
    if (!_showDialog) return;
    _showDialog = false;
    notifyListeners();
  }

  void resume() {
    if (!_active && !_showDialog) return;
    _active = false;
    _showDialog = false;
    _poller.start();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _app.removeListener(_onPreferencesChanged);
    _subscription?.cancel();
    super.dispose();
  }
}
