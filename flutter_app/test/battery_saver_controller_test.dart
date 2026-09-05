import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/battery_saver_controller.dart';
import 'package:omniterm/platform/battery_saver_notifications.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/shell_state.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';

import 'support/fake_secure_storage.dart';

class _BatteryMonitor implements BatteryMonitor {
  final statesController = StreamController<DevicePowerState>.broadcast();
  int percent = 100;
  Completer<int>? pendingLevel;

  @override
  Stream<DevicePowerState> get states => statesController.stream;

  @override
  Future<int> level() => pendingLevel?.future ?? Future<int>.value(percent);

  Future<void> close() => statesController.close();
}

class _Notifier implements BatterySaverNotifier {
  final calls = <String>[];

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<void> showActive({required int percent}) async => calls.add('active:$percent');

  @override
  Future<void> showPrompt({required int percent}) async => calls.add('prompt:$percent');
}

void main() {
  late AppDatabase db;
  late AppRepository repository;
  late AppState app;
  late ShellState shell;
  late TelemetryPoller poller;
  late HostStatusProbe hostProbe;
  late ShellViewModel terminals;
  late _BatteryMonitor monitor;
  late _Notifier notifier;
  BatterySaverController? controller;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repository = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repository);
    shell = ShellState();
    poller = TelemetryPoller(app);
    hostProbe = HostStatusProbe(repository);
    terminals = ShellViewModel(app);
    monitor = _BatteryMonitor();
    notifier = _Notifier();
  });

  tearDown(() async {
    controller?.dispose();
    terminals.dispose();
    poller.dispose();
    hostProbe.dispose();
    shell.dispose();
    app.dispose();
    await monitor.close();
    await db.close();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  BatterySaverController build() => BatterySaverController(
    app,
    shell,
    poller,
    hostProbe,
    terminals,
    monitor: monitor,
    notifier: notifier,
  );

  test('waits for persisted settings and never acts on cold-start defaults', () async {
    await repository.insertSetting('battery_saver_enabled', 'false');
    monitor.percent = 5;
    controller = build()..start();

    await settle();
    expect(controller!.showDialog, isFalse);

    await app.start();
    await settle();
    expect(app.settingsLoaded, isTrue);
    expect(controller!.showDialog, isFalse);
    expect(notifier.calls, isEmpty);
  });

  test('threshold only prompts until the user explicitly confirms', () async {
    await app.start();
    shell.setKeepScreenOnDirect(true);
    monitor.percent = 10;
    controller = build()..start();
    await settle();

    expect(controller!.showDialog, isTrue);
    expect(controller!.active, isFalse);
    expect(shell.isKeepScreenOnEnabled, isTrue);
    expect(notifier.calls, ['prompt:10']);

    controller!.confirm();
    await settle();
    expect(controller!.showDialog, isFalse);
    expect(controller!.active, isTrue);
    expect(shell.isKeepScreenOnEnabled, isFalse);
    expect(notifier.calls, ['prompt:10', 'active:10']);
  });

  test('not now suppresses repeats until charging or hysteresis recovery', () async {
    await app.start();
    monitor.percent = 10;
    controller = build()..start();
    await settle();
    controller!.dismissDialog();
    await settle();

    monitor.statesController.add(DevicePowerState.discharging);
    await settle();
    expect(controller!.showDialog, isFalse);

    monitor.percent = 30;
    monitor.statesController.add(DevicePowerState.discharging);
    await settle();
    monitor.percent = 10;
    monitor.statesController.add(DevicePowerState.discharging);
    await settle();
    expect(controller!.showDialog, isTrue);
    expect(notifier.calls.where((call) => call.startsWith('prompt:')).length, 2);
  });

  test('a stale level read cannot engage after the preference is disabled', () async {
    await app.start();
    final pending = Completer<int>();
    monitor.pendingLevel = pending;
    controller = build()..start();
    await settle();

    app.applyPreferences(app.preferences.copyWith(batterySaverEnabled: false));
    pending.complete(5);
    await settle();

    expect(controller!.showDialog, isFalse);
    expect(controller!.active, isFalse);
    expect(notifier.calls, isEmpty);
  });
}
