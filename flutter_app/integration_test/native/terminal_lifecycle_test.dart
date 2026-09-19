import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:provider/provider.dart';

import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/data/term/tmux_bootstrap.dart';
import 'package:omniterm/domain/app_pin.dart';
import 'package:omniterm/domain/external_action_guard.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/platform/external_launch.dart';
import 'package:omniterm/platform/screen_security.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';

const _enabled = bool.fromEnvironment('OMNITERM_E2E_HOSTS');
const _host = String.fromEnvironment('OMNITERM_E2E_HOST', defaultValue: '10.0.2.2');
const _user = String.fromEnvironment('OMNITERM_TEST_USER');
const _password = String.fromEnvironment('OMNITERM_TEST_PASSWORD');
const _lifecycle = MethodChannel('omniterm/test/activity_lifecycle');

/// Real Android Home/launcher transitions, not synthetic Flutter lifecycle notifications or the
/// navigation-only terminal-visible flag. Remote shell variables prove the same shell survived.
void main() {
  patrolTest(
    'SSH survives Home and explicit background; tmux leaves and resumes the same shell',
    ($) async {
      expect(_user, isNotEmpty);
      expect(_password, isNotEmpty);
      $.tester.binding.platformDispatcher.semanticsEnabledTestValue = false;
      app.main();
      await $.pumpAndSettle();
      final context = $.tester.element(find.byKey(const ValueKey('screen.servers')));
      final state = context.read<AppState>();
      final shell = context.read<ShellViewModel>();
      final navigation = context.read<NavigationController>();
      final transport = context.read<SshTransport>();
      final trust = context.read<SshHostKeyTrust>();
      final status = context.read<HostStatusProbe>()..stop();
      final telemetry = context.read<TelemetryPoller>()..stop();
      await $.tester.runAsync(() => state.saveSetting('flag_secure', 'true'));
      expect(
        await $.tester.runAsync(() => context.read<ScreenSecurity>().setSecure(secure: true)),
        isTrue,
      );
      final owner = Object();
      trust.registerApprovalHandler(owner, (request) {
        expect(request.host, _host, reason: 'Only repository fixture SSH keys may be approved');
        request.completer.complete(true);
      });
      addTearDown(() {
        trust.clearApprovalHandler(owner);
        status.stop();
        telemetry.stop();
      });
      final id = (await $.tester.runAsync(() => state.repository.insertServer(_server())))!;
      await _until($, () => state.servers.any((s) => s.id == id));
      final host = state.servers.singleWhere((s) => s.id == id);
      final credentials = SshCredentials(
        host: _host,
        port: 2205,
        username: _user,
        password: _password,
      );

      for (final keepAlive in [false, true]) {
        await $.tester.runAsync(() => state.saveSetting('background_keep_alive', '$keepAlive'));
        await _until($, () => shell.preferences.backgroundKeepAlive == keepAlive);
        for (final (persistent, control) in [(false, false), (true, false), (true, true)]) {
          final label =
              '${control
                  ? 'control'
                  : persistent
                  ? 'tmux'
                  : 'plain'}-$keepAlive';
          debugPrint('LIFECYCLE-E2E start $label');
          navigation.navigateTo(Screen.shell);
          await $.tester.pump();
          await $.tester.runAsync(
            () => shell.connect(host.copyWith(persistentSession: persistent), controlMode: control),
          );
          expect(shell.error, isNull);
          final original = shell.current!;
          final tmuxName = original.tmuxName;
          var reconnected = false;
          void observe() => reconnected |= original.reconnecting || !original.isOpen;
          original.addListener(observe);
          try {
            await _until(
              $,
              () =>
                  original.isOpen &&
                  (!control || !original.paneChangePending && original.controlPaneId != null),
            );
            final token = 'kept_${DateTime.now().microsecondsSinceEpoch}';
            expect(shell.typeText('OT_LIFECYCLE=$token\r'), isTrue);
            await _probe($, shell, original, token, 'before');
            // This handler exists only in androidTest and is installed before runDartTest.
            // Unlike rotation (handled by configChanges), it destroys the Activity while this
            // test and its server-side variable are live. A replacement must actually resume.
            await _recreate($);
            expect(shell.current, same(original));
            expect(reconnected, isFalse, reason: '$label recreation must not reopen SSH');
            await _probe($, shell, original, token, 'recreated');
            await _recreate($, finishAndRelaunch: true);
            expect(shell.current, same(original));
            expect(reconnected, isFalse, reason: '$label finish/relaunch must not reopen SSH');
            await _probe($, shell, original, token, 'relaunched');
            for (var cycle = 0; cycle < 3; cycle++) {
              await $.platform.android.pressHome();
              // Deliberate wall-clock background dwell, while no app frames can be pumped.
              await Future<void>.delayed(const Duration(seconds: 2));
              await $.platform.android.openApp(appId: 'com.jetsetslow.omniterm.app.flutter');
              await $.tester.pump();
              expect(shell.current, same(original));
              expect(reconnected, isFalse, reason: '$label Home cycle $cycle must not reopen SSH');
              await _probe($, shell, original, token, 'home$cycle');
            }
            // Exercise the actual guarded action: Send to background for plain SSH and Leave
            // resumable for tmux. Assert the destination so a still-open dialog cannot pass.
            navigation.navigateTo(Screen.servers);
            await $.tester.pump();
            if (persistent) {
              expect(find.byKey(const ValueKey('navigation.shellLeave')), findsOneWidget);
              // The same explicit resume entrypoint used by notification and shortcut delivery
              // must discard the old destination even when this session was already selected.
              expect(shell.resumeExisting(original.id), isTrue);
              await $.tester.pump();
              expect(find.byKey(const ValueKey('navigation.shellLeave')), findsNothing);
              expect(navigation.currentScreen, Screen.shell);
              expect(shell.current, same(original));
              expect(original.isOpen, isTrue);
              navigation.navigateTo(Screen.servers);
              await $.tester.pump();
            }
            if (persistent) original.removeListener(observe);
            await $(const ValueKey('navigation.shell.background')).tap();
            await _until($, () => navigation.currentScreen == Screen.servers);
            await $.platform.android.pressHome();
            await Future<void>.delayed(const Duration(seconds: 2));
            await $.platform.android.openApp(appId: 'com.jetsetslow.omniterm.app.flutter');
            if (persistent) {
              navigation.navigateTo(Screen.shell);
              await $.tester.pump();
            } else {
              // Exercise the real notification-action bridge after it was attached to a new
              // Activity. A working shell alone cannot prove shade actions still reach Dart.
              expect(
                await $.tester.runAsync(
                  () => _lifecycle.invokeMethod<bool>('resumeSession', {
                    'title': original.serverName,
                  }),
                ),
                isTrue,
                reason: 'The service must have posted a real notification to activate',
              );
              await _until($, () => navigation.currentScreen == Screen.shell);
            }
            if (!persistent) {
              expect(shell.current, same(original));
              expect(
                reconnected,
                isFalse,
                reason: '$label Send to background must preserve the channel',
              );
              await _probe($, shell, original, token, 'background');
            }
            original.removeListener(observe);
            if (persistent) {
              expect(shell.sessions, isNot(contains(original)));
              final saved = (await $.tester.runAsync(
                state.repository.getPersistentSessions,
              ))!.singleWhere((row) => row.tmuxName == tmuxName);
              expect(saved.backgroundedAt, greaterThan(0));
              shell.useControlMode = control;
              await $(ValueKey('shell.resumable.$tmuxName.resume')).tap();
              await _until($, () => shell.current != null && shell.current != original);
              final resumed = shell.current!;
              expect(resumed.tmuxName, tmuxName);
              expect(resumed.controlMode, control);
              await _until(
                $,
                () =>
                    resumed.isOpen &&
                    (!control || !resumed.paneChangePending && resumed.controlPaneId != null),
              );
              await _probe($, shell, resumed, token, 'resumed');
            }
            if (keepAlive && !persistent) {
              expect(
                await $.tester.runAsync(
                  () => _lifecycle.invokeMethod<bool>('disconnectSession', {
                    'title': original.serverName,
                  }),
                ),
                isTrue,
              );
              await _until($, () => !shell.sessions.contains(original));
              expect(original.isOpen, isFalse);
            }
            debugPrint('LIFECYCLE-E2E passed $label');
          } finally {
            original.removeListener(observe);
            for (final session in shell.sessions.toList()) {
              if (session.tmuxName != null) {
                await $.tester.runAsync(() => shell.leaveResumable(session));
              } else {
                shell.close(session);
              }
            }
            if (tmuxName != null) {
              await $.tester.runAsync(() => transport.exec(credentials, tmuxKillCommand(tmuxName)));
              await $.tester.runAsync(() => state.repository.deletePersistentSession(tmuxName));
              await $.tester.runAsync(shell.refreshResumable);
            }
          }
        }
      }
      await _checkLockedIntentRecreation($, $.tester.element(find.byType(MaterialApp)));
    },
    skip: !_enabled || !Platform.isAndroid,
  );
}

Future<void> _checkLockedIntentRecreation(PatrolIntegrationTester $, BuildContext context) async {
  final state = context.read<AppState>();
  final lock = context.read<AppLockController>();
  final navigation = context.read<NavigationController>();
  final external = context.read<ExternalLaunch>();
  final guard = context.read<ExternalActionGuard>();
  const pin = '246810';
  var received = 0;
  final subscription = external.actions.listen((_) => received++);
  try {
    await $.tester.runAsync(() async {
      await state.saveSetting('app_pin', await hashPinForStorage(pin));
      await state.saveSetting('app_lock_enabled', 'true');
      await lock.refresh();
    });
    navigation.navigateTo(Screen.servers);
    lock.lockNow();
    await $.tester.pump();
    expect(find.byKey(const ValueKey('lock.screen')), findsOneWidget);
    await $.tester.runAsync(() => _lifecycle.invokeMethod<void>('externalIntent'));
    await _until($, () => guard.pendingAction?.type == 'open_network');
    expect(received, 1);
    expect(navigation.currentScreen, Screen.servers, reason: 'Intents must wait behind the lock');
    await _recreate($);
    expect(lock.isLocked, isTrue);
    expect(find.byKey(const ValueKey('lock.screen')), findsOneWidget);
    expect(navigation.currentScreen, Screen.servers);
    expect(await $.tester.runAsync(external.takeInitialActions), isEmpty);
    expect(received, 1, reason: 'Recreation must not replay the consumed intent');
    await $.tester.enterText(find.byKey(const ValueKey('lock.pin')), pin);
    await $.tester.tap(find.byKey(const ValueKey('lock.submit')));
    await _until($, () => !lock.isLocked && navigation.currentScreen == Screen.network);
    expect(guard.pendingAction, isNull);
    navigation.navigateTo(Screen.servers);
    await $.tester.pump();
    await _recreate($);
    expect(
      navigation.currentScreen,
      Screen.servers,
      reason: 'The unlocked intent was consumed once',
    );
    expect(received, 1);
    await $.tester.runAsync(() => _lifecycle.invokeMethod<void>('externalIntent'));
    await _until($, () => received == 2 && navigation.currentScreen == Screen.network);
    debugPrint('LIFECYCLE-E2E passed lock and consume-once intents across recreation');
  } finally {
    await subscription.cancel();
    await $.tester.runAsync(() async {
      await state.saveSetting('app_lock_enabled', 'false');
      await state.saveSetting('app_pin', '');
      await lock.refresh();
    });
  }
}

Future<void> _recreate(PatrolIntegrationTester $, {bool finishAndRelaunch = false}) async {
  final evidence = await $.tester.runAsync(
    () => _lifecycle
        .invokeMapMethod<String, Object?>(finishAndRelaunch ? 'finishAndRelaunch' : 'recreate')
        .timeout(const Duration(seconds: 15)),
  );
  expect(evidence?['destroyed'], isTrue, reason: 'The original Activity must really be destroyed');
  expect(evidence?['sameEngine'], isTrue, reason: 'The SSH-owning Dart engine must survive');
  expect(evidence?['secureBefore'], isTrue, reason: 'The fixture must exercise FLAG_SECURE');
  expect(evidence?['secureAfter'], isTrue, reason: 'The replacement window must remain protected');
  // Flutter's EventChannel protocol must still own the subscription it created before attach.
  // Replacing its native handler creates an empty activeSink even though Dart is still listening:
  // the next cancellation then reports "No active stream to cancel" and never clears our sink.
  // Exercise the real protocol and restore the listeners, without replacing Dart's event handler.
  for (final name in ['omniterm/external_launch/events', 'omniterm/session_service/actions']) {
    await $.tester.runAsync(() async {
      final stream = MethodChannel(name);
      await stream.invokeMethod<void>('cancel');
      await stream.invokeMethod<void>('listen');
    });
    expect($.tester.takeException(), isNull, reason: '$name must retain its live subscription');
  }
  await $.tester.pump();
}

Future<void> _until(PatrolIntegrationTester $, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 50));
    await $.tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }
  expect(ready(), isTrue, reason: 'The SSH lifecycle condition did not become ready');
}

Future<void> _probe(
  PatrolIntegrationTester $,
  ShellViewModel vm,
  ShellSession session,
  String token,
  String stage,
) async {
  // Contiguous expected text appears only in the command RESULT, never in its echoed input.
  expect(vm.typeText('printf "${stage}_%s\\n" "\$OT_LIFECYCLE"\r'), isTrue);
  await _until(
    $,
    () => session.snapshot.rows.map((r) => r.text).join('\n').contains('${stage}_$token'),
  );
}

Server _server() => Server(
  id: 0,
  name: 'E2E lifecycle',
  host: _host,
  port: 2205,
  username: _user,
  serverColor: 'Default',
  authType: 'password',
  authPassword: _password,
  sudoPassword: '',
  notes: 'Repository-controlled disposable SSH fixture',
  keepAlive: 5,
  sshCompression: false,
  persistentSession: false,
  proxyCommand: '',
  proxyType: 'none',
  proxyHost: '',
  proxyPort: 0,
  proxyUser: '',
  proxyPassword: '',
  agentForwarding: false,
  healthScore: 100,
  lastLatency: 1,
  status: 'online',
  authStatus: 'ok',
);
