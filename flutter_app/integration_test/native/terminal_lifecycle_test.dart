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
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:omniterm/ui/theme/theme.dart';

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
            if (!keepAlive && !persistent) {
              await _checkHeldKey($, shell, original);
              await _checkKeyBarLayouts($, state, original);
            }
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
    // Kotlin's Unlock control is disabled while the field is empty. Render the entered PIN
    // before tapping, just as a real user sees the newly enabled control on the next frame.
    await $.tester.pump();
    expect(
      $.tester.widget<FilledButton>(find.byKey(const ValueKey('lock.submit'))).onPressed,
      isNotNull,
    );
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

Future<void> _checkHeldKey(
  PatrolIntegrationTester $,
  ShellViewModel shell,
  ShellSession session,
) async {
  final token = '${DateTime.now().microsecondsSinceEpoch}';
  // Capture actual bytes at the repository SSH fixture, with echo disabled so the command
  // cannot masquerade as its own result. The terminal mode is restored after the bounded read.
  final command =
      r'ot_keybar_state=$(stty -g); stty raw -echo min 0 time 20; '
      r'printf "\r\nKEYBAR_READY_%s\r\n" '
      "'$token'; "
      r'ot_keybar_bytes=$(dd bs=1 count=60 2>/dev/null | od -v -An -tu1); '
      r'stty "$ot_keybar_state"; printf "\r\nKEYBAR_%s:%s:END_%s\r\n" '
      "'$token' "
      r'"$ot_keybar_bytes" '
      "'$token'\r";
  expect(shell.typeText(command), isTrue);
  // Markers and byte values can wrap across painted cells; joining physical rows must not
  // insert new bytes into the server's result.
  String output() => session.snapshot.rows.map((row) => row.text).join();
  await _until($, () => output().contains('KEYBAR_READY_$token'));
  final up = find.byKey(const ValueKey('shell.key.↑'));
  final down = find.byKey(const ValueKey('shell.key.↓'));
  final pointer = await $.tester.startGesture($.tester.getCenter(up));
  try {
    final until = DateTime.now().add(const Duration(milliseconds: 680));
    while (DateTime.now().isBefore(until)) {
      await $.tester.pump(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  } finally {
    await pointer.up();
  }
  await _until($, () => output().contains(':END_$token'));
  final received = RegExp('KEYBAR_$token:([\\d\\s]+):END_$token').firstMatch(output());
  expect(received, isNotNull, reason: 'The fixture must report its actual received bytes');
  final bytes = received!.group(1)!.trim().split(RegExp(r'\s+')).map(int.parse).toList();
  expect(bytes.length, greaterThanOrEqualTo(6), reason: 'Holding ↑ must send repeated keys');
  expect(bytes.length % 3, 0);
  for (var index = 0; index < bytes.length; index += 3) {
    expect(bytes.sublist(index, index + 3), [27, 91, 65]);
  }
  expect($.tester.getCenter(up).dx, $.tester.getCenter(down).dx);
  expect($.tester.getCenter(down).dy, greaterThan($.tester.getCenter(up).dy));
  debugPrint('KEYBAR-E2E fixture received ${bytes.length ~/ 3} Up sequences from one hold');
}

// Exercise the actual scaffold and Android IME. A ShellScreen-only widget test cannot catch
// an inset being consumed by Scaffold or the compact flag failing to reach the screen.
Future<void> _checkKeyBarLayouts(
  PatrolIntegrationTester $,
  AppState state,
  ShellSession session,
) async {
  const capture = bool.fromEnvironment('OMNITERM_E2E_VISUALS');
  final original = state.preferences;
  final settings = $.tester.element(find.byType(MaterialApp)).read<SettingsViewModel>();
  final security = $.tester.element(find.byType(MaterialApp)).read<ScreenSecurity>();
  final up = find.byKey(const ValueKey('shell.key.↑'));
  final down = find.byKey(const ValueKey('shell.key.↓'));
  final bar = find.byKey(const ValueKey('shell.keyBar'));
  Future<void> snapshot(String name) async {
    expect($.tester.takeException(), isNull, reason: name);
    if (!capture) return;
    await $.tester.pump(const Duration(milliseconds: 200));
    expect(await _lifecycle.invokeMethod<bool>('captureKeyBar', {'name': name}), isTrue);
  }

  Future<void> rotate(DeviceOrientation orientation) async {
    await SystemChrome.setPreferredOrientations([orientation]);
    await _until($, () {
      final size = $.tester.view.physicalSize;
      return orientation == DeviceOrientation.portraitUp
          ? size.height > size.width
          : size.width > size.height;
    });
    await $.tester.pump(const Duration(milliseconds: 300));
  }

  try {
    settings.update(
      (_) => original.copyWith(
        darkMode: true,
        accessibility: false,
        amoled: false,
        textScalePercent: 92,
        blockScreenshots: capture ? false : original.blockScreenshots,
      ),
    );
    await $.tester.runAsync(settings.save);
    if (capture) expect(await security.setSecure(secure: false), isTrue);
    await rotate(DeviceOrientation.landscapeLeft);
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    await _until($, () => $.tester.view.viewInsets.bottom > 0);
    await $.tester.pump(const Duration(milliseconds: 300));
    expect(
      $.tester.getCenter(up).dy,
      $.tester.getCenter(down).dy,
      reason: 'Landscape with the Android IME must use one compact key row',
    );
    expect($.tester.getSize(bar).height, 42);
    expect(find.byKey(const ValueKey('shell.sessionBar')), findsNothing);
    final safeLeft = $.tester.view.viewPadding.left / $.tester.view.devicePixelRatio;
    expect(
      $.tester.getTopLeft(bar).dx,
      greaterThanOrEqualTo(safeLeft),
      reason: 'The compact keyboard must stay inside the Android display cutout inset',
    );
    final sym = $.tester.getCenter(find.byKey(const ValueKey('shell.key.SYM')));
    final fn = $.tester.getCenter(find.byKey(const ValueKey('shell.key.FN')));
    await snapshot('landscape-nav');
    await $(const ValueKey('shell.key.FN')).tap();
    expect($.tester.getCenter(find.byKey(const ValueKey('shell.key.NAV'))), fn);
    expect($.tester.getCenter(find.byKey(const ValueKey('shell.key.SYM'))), sym);
    await snapshot('landscape-function');
    await $(const ValueKey('shell.key.SYM')).tap();
    expect($.tester.getCenter(find.byKey(const ValueKey('shell.key.FN'))), fn);
    expect($.tester.getCenter(find.byKey(const ValueKey('shell.key.SYM'))), sym);
    await snapshot('landscape-symbol');
    await $(const ValueKey('shell.key.SYM')).tap();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await _until(
      $,
      () => $.tester.view.viewInsets.bottom == 0 && $.tester.getSize(bar).height == 80,
    );
    expect($.tester.getSize(bar).height, 80, reason: 'Closing the IME restores both rows');
    await snapshot('landscape-no-ime');
    await rotate(DeviceOrientation.portraitUp);
    for (final (name, dark, contrast, scale) in [
      ('dark', true, false, 'normal'),
      ('light', false, false, 'normal'),
      ('contrast', true, true, 'normal'),
      ('large', true, false, 'large'),
    ]) {
      settings.update(
        (_) => original.copyWith(
          darkMode: dark,
          accessibility: contrast,
          amoled: false,
          textScalePercent: scale == 'large' ? 110 : 92,
          blockScreenshots: capture ? false : original.blockScreenshots,
        ),
      );
      await $.tester.runAsync(settings.save);
      final mode = themeModeFor(isDark: dark, highContrast: contrast, amoled: false);
      final expected = omniTheme(mode, Brightness.light).colorScheme;
      await _until($, () {
        final context = $.tester.element(bar);
        final actual = Theme.of(context).colorScheme;
        return actual.surface == expected.surface &&
            actual.outline == expected.outline &&
            MediaQuery.textScalerOf(context).scale(12) == 12 * (scale == 'large' ? 1.1 : .92);
      });
      await $.tester.pump(const Duration(milliseconds: 350));
      expect($.tester.getSize(bar).height, 80);
      expect($.tester.getCenter(up).dx, $.tester.getCenter(down).dx);
      expect($.tester.getCenter(up).dy, lessThan($.tester.getCenter(down).dy));
      await snapshot('portrait-$name-nav');
      await $(const ValueKey('shell.key.FN')).tap();
      expect(find.byKey(const ValueKey('shell.key.F12')), findsOneWidget);
      await snapshot('portrait-$name-function');
      await $(const ValueKey('shell.key.SYM')).tap();
      expect(find.byKey(const ValueKey('shell.key.!')), findsOneWidget);
      await snapshot('portrait-$name-symbol');
      await $(const ValueKey('shell.key.SYM')).tap();
      session.setReadOnly(true);
      await $.tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('shell.keyBar.readOnly')), findsOneWidget);
      expect(up, findsNothing);
      expect(find.byKey(const ValueKey('shell.key.PGUP')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.key.PGDN')), findsOneWidget);
      await snapshot('portrait-$name-readonly');
      session.setReadOnly(false);
      await $.tester.pump();
    }
  } finally {
    session.setReadOnly(false);
    settings.update((_) => original);
    await $.tester.runAsync(settings.save);
    // Until the Settings parity checkpoint fixes nullable-theme persistence, explicitly restore
    // a System value that encode() omits so this fixture does not leak its last selected theme.
    if (original.darkMode == null) await state.saveSetting('dark_mode', '');
    if (capture) expect(await security.setSecure(secure: true), isTrue);
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await _until($, () => $.tester.view.viewInsets.bottom == 0);
    await rotate(DeviceOrientation.portraitUp);
    await SystemChrome.setPreferredOrientations([]);
  }
  debugPrint('KEYBAR-E2E real Android IME, layers, themes and read-only layouts passed');
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
