import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/view_model/alerts_view_model.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/fleet_view_model.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/infra_view_model.dart';
import 'package:omniterm/ui/view_model/monitor_view_model.dart';
import 'package:omniterm/ui/view_model/network_view_model.dart';
import 'package:omniterm/ui/view_model/scripts_view_model.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every route and subtab opens in every app theme and orientation', (
    tester,
  ) async {
    installErrorLocationProbe();
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final initialContext = tester.element(
      find.byKey(const ValueKey('screen.servers')),
    );
    final appState = initialContext.read<AppState>();
    final navigation = initialContext.read<NavigationController>();
    final settings = initialContext.read<SettingsViewModel>();
    final hostProbe = initialContext.read<HostStatusProbe>()..stop();
    final poller = initialContext.read<TelemetryPoller>()..stop();
    final fleet = initialContext.read<FleetViewModel>();
    final monitor = initialContext.read<MonitorViewModel>();
    final infra = initialContext.read<InfraViewModel>();
    final sftp = initialContext.read<SftpViewModel>();
    final alerts = initialContext.read<AlertsViewModel>();
    final scripts = initialContext.read<ScriptsViewModel>();
    final network = initialContext.read<NetworkViewModel>();
    final originalPreferences = settings.saved;
    final renderFailures = <String>[];

    addTearDown(() async {
      hostProbe.stop();
      poller.stop();
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      // The fixture host is deliberately *not* removed here. A teardown runs after drift's isolate
      // channel has closed, so any query from one throws — the walkthrough's fresh-install test
      // clears the table itself instead, which also makes it independent of the order these files
      // happen to run in.
    });

    // A repository-owned fixture unlocks the real online-host branches without depending on the
    // workstation or somebody's personal lab. Port 1 on loopback refuses immediately when a tab
    // starts an SSH load, so the surface can exercise its loading/error state without a long wait.
    await appState.repository.insertServer(
      const Server(
        id: 0,
        name: 'Surface Fixture',
        host: '127.0.0.1',
        port: 1,
        username: 'fixture',
        groupName: 'E2E',
        serverColor: 'Default',
        authType: 'password',
        sudoPassword: '',
        notes: 'Repository-controlled integration fixture',
        keepAlive: 30,
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
        authStatus: 'unknown',
      ),
    );
    for (var attempt = 0; attempt < 20 && appState.servers.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(appState.servers, hasLength(1));

    // The five schemes `themeModeFor` can select. High contrast is included because those two
    // schemes were unreachable until defect 44 wired the preference in — so until now they had never
    // been painted against a single screen, and a colour role that is never rendered is a colour
    // role nobody has checked is legible.
    //
    // AMOLED is deliberately left on for the high-contrast rows: it is the combination that proves
    // precedence holds end to end, not just in `themeModeFor`'s unit tests.
    final variants = <(String, bool, bool, bool, int)>[
      ('light', false, false, false, 100),
      ('dark', true, false, false, 100),
      ('amoled', true, true, false, 100),
      ('contrast-dark', true, true, true, 100),
      ('contrast-light', false, true, true, 100),
      // The largest text the Settings screen offers. Every fixed-height row, chip and toolbar in
      // the app is an overflow candidate at 200%, and nothing exercised it — a user who needs large
      // text is exactly the user least able to work around a clipped control.
      ('dark-200pc-text', true, false, false, 200),
    ];
    final orientations = <(String, List<DeviceOrientation>, Orientation)>[
      ('portrait', const [DeviceOrientation.portraitUp], Orientation.portrait),
      (
        'landscape',
        const [DeviceOrientation.landscapeLeft],
        Orientation.landscape,
      ),
    ];

    for (final (themeName, dark, amoled, contrast, textScale) in variants) {
      settings.update(
        (current) => current.copyWith(
          darkMode: dark,
          amoled: amoled,
          accessibility: contrast,
          textScalePercent: textScale,
        ),
      );
      await settings.save();
      await tester.pump(const Duration(milliseconds: 300));

      // Each variant must actually reach the widget tree. Without this the loop could paint one
      // scheme five times and still pass — which is precisely how the high-contrast schemes stayed
      // unrendered and unnoticed until defect 44.
      //
      // Checked against the *expected* scheme rather than for uniqueness: `amoled` and
      // `highContrastDark` share a black background quite legitimately, so a uniqueness test would
      // fail on a correct app. The primary colour is compared too, because the background alone
      // cannot tell those two apart.
      await _waitForTheme(
        tester,
        themeModeFor(isDark: dark, highContrast: contrast, amoled: amoled),
        themeName,
      );
      // Asserted separately: text scale does not touch ThemeData, so the theme guard above cannot
      // show whether it landed, and a scale that never applied would make this row a duplicate of
      // the plain dark one.
      await _waitForTextScale(tester, textScale, themeName);

      for (final (orientationName, allowed, expectedOrientation)
          in orientations) {
        await SystemChrome.setPreferredOrientations(allowed);
        await _waitForOrientation(tester, expectedOrientation);

        for (final screen in Screen.values) {
          navigation.navigateTo(screen);
          await tester.pump(const Duration(milliseconds: 180));
          _expectSurface(
            tester,
            screen,
            '$themeName/$orientationName/${screen.name}',
            renderFailures,
          );

          switch (screen) {
            case Screen.fleet:
              for (final tab in FleetTab.values) {
                fleet.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/fleet/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.monitor:
              for (final tab in MonitorTab.values) {
                monitor.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/monitor/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.sftp:
              for (final tab in SftpTab.values) {
                sftp.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/sftp/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.infra:
              for (final tab in InfraTab.values) {
                infra.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/infra/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.alerts:
              for (final tab in AlertsTab.values) {
                alerts.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/alerts/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.quickScripts:
              for (final tab in ScriptsTab.values) {
                scripts.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/scripts/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.network:
              for (final tab in NetworkTab.values) {
                network.activeTab = tab;
                await _expectSubtab(
                  tester,
                  '$themeName/$orientationName/network/${tab.name}',
                  renderFailures,
                );
              }
            case Screen.servers ||
                Screen.shell ||
                Screen.tools ||
                Screen.authKeys ||
                Screen.backup ||
                Screen.healthScoring ||
                Screen.settings ||
                Screen.about:
              break;
          }
        }
      }
    }
    settings.update((_) => originalPreferences);
    await settings.save();
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);

    expect(renderFailures, isEmpty, reason: renderFailures.join('\n'));
  });
}

/// Waits until the live text scaler is the one the preference asked for.
Future<void> _waitForTextScale(
  WidgetTester tester,
  int percent,
  String label,
) async {
  final expected = percent / 100.0;
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final scaler = MediaQuery.textScalerOf(
      tester.element(find.byType(Scaffold).first),
    );
    if ((scaler.scale(100) - 100 * expected).abs() < 0.5) return;
  }
  fail('$label never reached the widget tree: text scale did not change');
}

/// Waits until the live theme is the one [mode] resolves to.
///
/// A settings save reaches the tree through a notification and a rebuild, so sampling once reads the
/// previous variant and fails on this helper's own latency rather than on anything real.
Future<void> _waitForTheme(
  WidgetTester tester,
  OmniThemeMode mode,
  String label,
) async {
  // Sampled from a *descendant* of MaterialApp. `Theme.of` on MaterialApp's own element resolves
  // the ancestor fallback rather than the theme MaterialApp installs beneath itself, which reads as
  // a constant and would make this check pass no matter what the app rendered.
  Element themedElement() => tester.element(find.byType(Scaffold).first);
  final expected = omniTheme(
    mode,
    MediaQuery.platformBrightnessOf(themedElement()),
  );
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final live = Theme.of(themedElement());
    if (live.scaffoldBackgroundColor == expected.scaffoldBackgroundColor &&
        live.colorScheme.primary == expected.colorScheme.primary) {
      return;
    }
  }
  fail('$label never reached the widget tree: the theme did not change');
}

Future<void> _waitForOrientation(
  WidgetTester tester,
  Orientation expected,
) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final route = find.byKey(
      ValueKey('screen.${_visibleScreen(tester)?.name ?? Screen.servers.name}'),
    );
    if (route.evaluate().isNotEmpty &&
        MediaQuery.orientationOf(tester.element(route)) == expected) {
      return;
    }
  }
  fail('device did not rotate to ${expected.name}');
}

Screen? _visibleScreen(WidgetTester tester) {
  for (final screen in Screen.values) {
    if (find.byKey(ValueKey('screen.${screen.name}')).evaluate().isNotEmpty) {
      return screen;
    }
  }
  return null;
}

void _expectSurface(
  WidgetTester tester,
  Screen screen,
  String label,
  List<String> renderFailures,
) {
  final route = find.byKey(ValueKey('screen.${screen.name}'));
  expect(route, findsOneWidget, reason: '$label did not build its route');
  expect(
    tester.getSize(route).isEmpty,
    isFalse,
    reason: '$label collapsed to a zero-sized surface',
  );
  final exception = tester.takeException();
  if (exception != null) {
    // The widget that caused it, not just the message. `$exception` alone gives "overflowed by 44
    // pixels" with no file or line, which is not enough to fix anything — the last two rounds of
    // this work were spent guessing which Column it meant.
    final where = _lastErrorWidget;
    renderFailures.add('$label: $exception${where == null ? '' : ' [$where]'}');
  }
  _lastErrorWidget = null;
}

/// Where the most recent framework error was raised, captured by [installErrorLocationProbe].
String? _lastErrorWidget;

/// Records the error-causing widget's location alongside each failure.
///
/// `FlutterErrorDetails` carries it; `takeException` does not, so it has to be read as the error is
/// reported rather than after the fact.
void installErrorLocationProbe() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.toString();
    final match = RegExp(r'([A-Za-z_]+\.dart):(\d+):(\d+)').firstMatch(text);
    if (match != null) _lastErrorWidget = match.group(0);
    previous?.call(details);
  };
}

Future<void> _expectSubtab(
  WidgetTester tester,
  String label,
  List<String> renderFailures,
) async {
  await tester.pump(const Duration(milliseconds: 140));
  final exception = tester.takeException();
  if (exception != null) renderFailures.add('$label: $exception');
  expect(
    find.byType(Text),
    findsWidgets,
    reason: '$label rendered no readable content',
  );
}
