import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:provider/provider.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/platform/screen_security.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/tools/settings_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';

const _capture = bool.fromEnvironment('OMNITERM_E2E_SETTINGS_VISUALS');
const _lifecycle = MethodChannel('omniterm/test/activity_lifecycle');

void main() {
  patrolTest(
    'Kotlin Settings cards and popups remain reachable at phone size',
    ($) async {
      $.tester.binding.platformDispatcher.semanticsEnabledTestValue = false;
      app.main();
      await $.pumpAndSettle();
      final context = $.tester.element(find.byKey(const ValueKey('screen.servers')));
      final state = context.read<AppState>();
      final settings = context.read<SettingsViewModel>();
      final navigation = context.read<NavigationController>();
      final security = context.read<ScreenSecurity>();
      final status = context.read<HostStatusProbe>()..stop();
      final telemetry = context.read<TelemetryPoller>()..stop();
      await $.tester.runAsync(settings.start);
      final original = state.preferences;
      try {
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        final headings = [
          'SECURITY GATE APP LOCK',
          'DISPLAY BEHAVIOR',
          'METRICS DATA PRUNING',
          'TERMINAL',
          'ALERT HISTORY',
          'SFTP TRANSFER WARNINGS',
        ];
        final names = ['security', 'display', 'metrics', 'terminal', 'alerts', 'sftp'];
        for (final (name, dark, contrast, scale) in [
          ('dark', true, false, 92),
          ('light', false, false, 92),
          ('contrast', true, true, 92),
          ('large', true, false, 110),
        ]) {
          navigation.navigateTo(Screen.tools);
          await $.tester.pump();
          settings.update(
            (_) => original.copyWith(
              darkMode: dark,
              accessibility: contrast,
              amoled: false,
              textScalePercent: scale,
              blockScreenshots: !_capture,
              appLockEnabled: false,
              useBiometrics: false,
              batterySaverEnabled: false,
              terminalFontSize: 10,
              terminalScrollbackLimit: 10000,
              terminalTheme: 'system',
              sftpWarnFileCount: 50,
              sftpWarnGigabytes: 1,
            ),
          );
          await $.tester.runAsync(settings.save);
          settings.dismissStatus();
          if (_capture) expect(await security.setSecure(secure: false), isTrue);
          navigation.navigateTo(Screen.settings);
          await $.pumpAndSettle();
          final settingsContext = $.tester.element(find.byType(SettingsScreen));
          final expected = omniTheme(
            contrast
                ? OmniThemeMode.highContrastDark
                : dark
                ? OmniThemeMode.dark
                : OmniThemeMode.light,
            dark ? Brightness.dark : Brightness.light,
          );
          expect(Theme.of(settingsContext).colorScheme.surface, expected.colorScheme.surface);
          final scaler = MediaQuery.textScalerOf(settingsContext);
          expect(scaler.scale(16), closeTo(16 * scale / 100, .01));
          expect(find.text('SECURITY GATE APP LOCK'), findsOneWidget);
          await _snapshot($, '$name-top');
          for (var i = 1; i < headings.length; i++) {
            await $(find.text(headings[i])).scrollTo();
            expect(find.byKey(const ValueKey('settings.save')).hitTestable(), findsOneWidget);
            await _snapshot($, '$name-${names[i]}');
          }
          final list = find.descendant(
            of: find.byKey(const ValueKey('settings.list')),
            matching: find.byWidgetPredicate(
              (widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down,
            ),
          );
          $.tester.state<ScrollableState>(list).position.jumpTo(0);
          await $.pumpAndSettle();
          await $(const ValueKey('settings.appLockEnabled')).tap();
          expect(find.text('Configure Security PIN'), findsOneWidget);
          await _snapshot($, '$name-pin-setup');
          await $(const ValueKey('settings.pin.cancel')).tap();
          await $(const ValueKey('settings.darkMode')).scrollTo().tap();
          expect(find.text('System Default'), findsOneWidget);
          await _snapshot($, '$name-theme-menu');
          await $.platformAutomator.android.pressBack();
          await $.pumpAndSettle();
          expect(settings.isDirty, isFalse);
        }
      } finally {
        settings.revert();
        settings.update((_) => original);
        await $.tester.runAsync(settings.save);
        await security.setSecure(secure: original.blockScreenshots);
        await SystemChrome.setPreferredOrientations([]);
        status.stop();
        telemetry.stop();
      }
    },
    semanticsEnabled: false,
    skip: !Platform.isAndroid,
  );
  final binding = WidgetsBinding.instance;
  binding.platformDispatcher.onSemanticsEnabledChanged = () {};
  final semantics = binding.ensureSemantics();
  tearDownAll(semantics.dispose);
}

Future<void> _snapshot(PatrolIntegrationTester $, String name) async {
  expect($.tester.takeException(), isNull, reason: name);
  if (!_capture) return;
  await $.tester.pump(const Duration(milliseconds: 350));
  expect(await _lifecycle.invokeMethod<bool>('captureKeyBar', {'name': name}), isTrue);
}
