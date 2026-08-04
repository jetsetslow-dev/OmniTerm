import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/settings_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late SettingsViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    // Thirty-odd rows across five sections; the default surface would leave most of them unlaid-out.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = SettingsViewModel(app);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('the sections and their controls render', (tester) async {
    await pump(tester);

    for (final section in ['Appearance', 'Monitoring', 'Terminal', 'File transfers']) {
      expect(find.text(section), findsOneWidget, reason: section);
    }
    expect(find.byKey(const ValueKey('settings.darkMode')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings.telemetryInterval.value')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings.terminalTheme')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('values come from the store', (tester) async {
    await repo.insertSetting('telemetry_interval', '60');
    await repo.insertSetting('terminal_theme', 'Nord');
    await pump(tester);

    expect(find.text('60s'), findsOneWidget);
    expect(vm.draft.terminalTheme, 'Nord');
    await finish(tester);
  });

  testWidgets('nothing is written until Save', (tester) async {
    // Applying per keystroke would restart the telemetry poller on the way from "1" to "15".
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('settings.telemetryInterval.up')));
    await tester.pumpAndSettle();

    expect(vm.isDirty, isTrue);
    expect(await repo.getSetting('telemetry_interval'), isNull);

    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await tester.pumpAndSettle();

    expect(await repo.getSetting('telemetry_interval'), '20');
    expect(find.textContaining('saved'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('save is disabled until something changes', (tester) async {
    await pump(tester);
    var save = tester.widget<FilledButton>(find.byKey(const ValueKey('settings.save')));
    expect(save.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('settings.amoled')));
    await tester.pumpAndSettle();
    save = tester.widget<FilledButton>(find.byKey(const ValueKey('settings.save')));
    expect(save.onPressed, isNotNull);
    await finish(tester);
  });

  testWidgets('discard appears only when dirty and puts values back', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('settings.revert')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings.telemetryInterval.up')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings.revert')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings.revert')));
    await tester.pumpAndSettle();

    expect(vm.isDirty, isFalse);
    expect(find.text('15s'), findsOneWidget);
    await finish(tester);
  });

  group('bounds are visible, not silent', () {
    testWidgets('a stepper disables at its floor and ceiling', (tester) async {
      // A button that does nothing when tapped is worse than one that is plainly unavailable.
      await repo.insertSetting(
        'telemetry_interval',
        '${PreferenceLimits.telemetryInterval.min}',
      );
      await pump(tester);

      final down =
          tester.widget<IconButton>(find.byKey(const ValueKey('settings.telemetryInterval.down')));
      expect(down.onPressed, isNull);

      vm.update((p) => p.copyWith(
            telemetryIntervalSeconds: PreferenceLimits.telemetryInterval.max,
          ));
      await tester.pumpAndSettle();
      final up =
          tester.widget<IconButton>(find.byKey(const ValueKey('settings.telemetryInterval.up')));
      expect(up.onPressed, isNull);
      await finish(tester);
    });

    testWidgets('stepping never leaves the range', (tester) async {
      await repo.insertSetting('terminal_scrollback_limit', '600');
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('settings.terminalScrollbackLimit.down')));
      await tester.pumpAndSettle();

      expect(
        vm.draft.terminalScrollbackLimit,
        greaterThanOrEqualTo(PreferenceLimits.terminalScrollback.min),
      );
      await finish(tester);
    });
  });

  group('dependent settings', () {
    testWidgets('a dependent switch is disabled, not hidden', (tester) async {
      // Hiding it would erase both the option and its precondition from view.
      await pump(tester);

      final biometrics =
          tester.widget<SwitchListTile>(find.byKey(const ValueKey('settings.biometrics')));
      expect(biometrics.onChanged, isNull, reason: 'the app lock is off');

      vm.update((p) => p.copyWith(appLockEnabled: true));
      await tester.pumpAndSettle();

      final enabled =
          tester.widget<SwitchListTile>(find.byKey(const ValueKey('settings.biometrics')));
      expect(enabled.onChanged, isNotNull);
      await finish(tester);
    });

    testWidgets('the battery threshold appears only when the saver is on', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('settings.batterySaverThreshold.value')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings.batterySaverEnabled')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings.batterySaverThreshold.value')), findsNothing);
      await finish(tester);
    });
  });

  testWidgets('a contradictory combination is warned about, not blocked', (tester) async {
    // Refusing a legal combination outright would be the app overruling the user.
    await pump(tester);
    expect(find.byKey(const ValueKey('settings.warning.0')), findsNothing);

    vm.update((p) => p.copyWith(useBiometrics: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings.warning.0')), findsOneWidget);
    expect(find.textContaining('does nothing while the app lock is off'), findsOneWidget);

    final save = tester.widget<FilledButton>(find.byKey(const ValueKey('settings.save')));
    expect(save.onPressed, isNotNull, reason: 'a warning is advice, not a veto');
    await finish(tester);
  });

  testWidgets('hide-addresses explains when it is for, and takes effect on save',
      (tester) async {
    await pump(tester);
    expect(find.textContaining('sharing a screen'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings.hideSensitiveInfo')));
    await tester.pumpAndSettle();
    expect(HostDisplay.instance.hideSensitiveInfo, isFalse, reason: 'not saved yet');

    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await tester.pumpAndSettle();
    expect(HostDisplay.instance.hideSensitiveInfo, isTrue);
    await finish(tester);
  });

  testWidgets('resetting asks first and says what it does not touch', (tester) async {
    await repo.insertSetting('telemetry_interval', '120');
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('settings.reset')));
    await tester.pumpAndSettle();
    expect(find.textContaining('are not affected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings.reset.cancel')));
    await tester.pumpAndSettle();
    expect(vm.saved.telemetryIntervalSeconds, 120);

    await tester.tap(find.byKey(const ValueKey('settings.reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings.reset.confirm')));
    await tester.pumpAndSettle();

    expect(vm.saved, AppPreferences.defaults);
    await finish(tester);
  });

  testWidgets('saving does not disturb unrelated stored settings', (tester) async {
    await repo.insertSetting('sftp_bookmarks_1', '/srv|||/etc');
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('settings.amoled')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await tester.pumpAndSettle();

    expect(await repo.getSetting('sftp_bookmarks_1'), '/srv|||/etc');
    await finish(tester);
  });
}
