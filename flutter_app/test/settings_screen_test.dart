import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
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

  /// Pumps the screen with a **real** `AppLockController`, which the harness above deliberately
  /// omits.
  ///
  /// Bounded pumps rather than `pumpAndSettle`: a live controller keeps a background-lock timer, so
  /// settling waits on a timer that is meant to keep repeating. That is the same obstacle recorded
  /// against defect 62, and it is why the enable-with-PIN path had never been driven here.
  Future<AppLockController> pumpWithLock(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = SettingsViewModel(app);
    final lock = AppLockController(repo);
    await lock.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
          ChangeNotifierProvider<AppLockController>.value(value: lock),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return lock;
  }

  /// Like [pumpWithLock] but at a real phone's landscape geometry and text scale.
  ///
  /// Every other harness here uses a 1200x4000 surface so all thirty-odd settings rows lay out. That
  /// is right for driving the screen and wrong for judging whether anything fits: the PIN dialog has
  /// never been rendered at a size a phone actually has.
  Future<AppLockController> pumpWithLockAt(
    WidgetTester tester, {
    required Size size,
    required double textScale,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = SettingsViewModel(app);
    final lock = AppLockController(repo);
    await lock.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
          ChangeNotifierProvider<AppLockController>.value(value: lock),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
            child: const Scaffold(body: SettingsScreen()),
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return lock;
  }

  /// Advances a few frames without waiting for the lock timer to stop repeating.
  Future<void> step(WidgetTester tester) async {
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('the PIN dialog fits a landscape phone at 200% text, error and all', (tester) async {
    // The class defect 112 belongs to: a branch nothing renders is a branch nothing has measured.
    // `settings.pin.error` appears in no test in this repository, and the harnesses here all use a
    // 1200x4000 surface, so this dialog had never been laid out at a size a phone actually has —
    // and an AlertDialog's content is *not* scrollable unless it asks to be.
    final overflows = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) overflows.add(details.toString());
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    // A small phone in landscape — 640x360 logical, tighter than the emulator's 914x411 and the
    // hardest case this dialog has to survive.
    await pumpWithLockAt(tester, size: const Size(640, 360), textScale: 2);

    // At a real phone size the list scrolls, so both controls have to be brought into view first —
    // which is itself the point: the tall harness never exercised that either.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings.appLockEnabled')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await step(tester);
    await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
    await step(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings.save')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await step(tester);
    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await step(tester);
    expect(find.byKey(const ValueKey('settings.pin.dialog')), findsOneWidget);

    // Mismatched entries, so the error line is present — the tallest the dialog ever gets.
    await tester.enterText(find.byKey(const ValueKey('settings.pin.first')), '4913');
    await tester.enterText(find.byKey(const ValueKey('settings.pin.second')), '1234');
    await step(tester);
    await tester.tap(find.byKey(const ValueKey('settings.pin.confirm')));
    await step(tester);

    expect(find.byKey(const ValueKey('settings.pin.error')), findsOneWidget, reason: 'error shown');
    expect(overflows, isEmpty, reason: 'the PIN dialog overflowed: ${overflows.join('; ')}');
    await finish(tester);
  });

  group('enabling App Lock actually turns it on', () {
    /// The open question from the device suite: on a device the switch showed *on* after saving,
    /// while the confirmation that fires on the way back off never appeared — and that confirmation
    /// keys off `vm.saved.appLockEnabled`, not the draft. Either the device test drove the screen
    /// faster than the save committed, or enabling App Lock sets a PIN **without turning the lock
    /// on**, which would be a switch reporting protection it is not providing.
    testWidgets('the preference is saved, not just the PIN', (tester) async {
      final lock = await pumpWithLock(tester);

      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await step(tester);
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await step(tester);

      expect(
        find.byKey(const ValueKey('settings.pin.dialog')),
        findsOneWidget,
        reason: 'enabling the lock must collect a PIN',
      );
      await tester.enterText(find.byKey(const ValueKey('settings.pin.first')), '4913');
      await tester.enterText(find.byKey(const ValueKey('settings.pin.second')), '4913');
      await step(tester);
      await tester.tap(find.byKey(const ValueKey('settings.pin.confirm')));
      await step(tester);

      expect(lock.hasStoredPin, isTrue, reason: 'the PIN was not stored');
      expect(
        vm.saved.appLockEnabled,
        isTrue,
        reason:
            'the PIN was stored but the lock was left off — a switch that reports protection '
            'it is not providing',
      );
      expect(lock.isConfigured, isTrue);
    });

    testWidgets('with a PIN stored, saving asks for it first', (tester) async {
      // Defect 62's uncovered wiring. That entry recorded the gated path as undrivable here,
      // because a live `AppLockController` stops `pumpAndSettle` quieting. Bounded pumps make it
      // drivable, so the join between `hasStoredPin` and the save is no longer an assumption.
      await repo.insertSetting('app_pin', '4913');
      final lock = await pumpWithLock(tester);
      expect(lock.hasStoredPin, isTrue);

      await tester.tap(find.byKey(const ValueKey('settings.blockScreenshots')));
      await step(tester);
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await step(tester);

      expect(
        find.byKey(const ValueKey('sudoAuth.dialog')),
        findsOneWidget,
        reason:
            'settings saved without proving who was asking, and disabling the lock from here '
            'clears the stored PIN outright',
      );

      // Cancelling must change nothing.
      final before = vm.saved.blockScreenshots;
      await tester.tap(find.byKey(const ValueKey('sudoAuth.cancel')));
      await step(tester);
      expect(vm.saved.blockScreenshots, before);
    });
  });

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
    await repo.insertSetting('terminal_theme', 'light');
    await pump(tester);

    expect(find.text('60s'), findsOneWidget);
    expect(vm.draft.terminalTheme, 'light');
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

    await tester.tap(find.byKey(const ValueKey('settings.accessibility')));
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
      await repo.insertSetting('telemetry_interval', '${PreferenceLimits.telemetryInterval.min}');
      await pump(tester);

      final down = tester.widget<IconButton>(
        find.byKey(const ValueKey('settings.telemetryInterval.down')),
      );
      expect(down.onPressed, isNull);

      vm.update(
        (p) => p.copyWith(telemetryIntervalSeconds: PreferenceLimits.telemetryInterval.max),
      );
      await tester.pumpAndSettle();
      final up = tester.widget<IconButton>(
        find.byKey(const ValueKey('settings.telemetryInterval.up')),
      );
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

      final biometrics = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings.biometrics')),
      );
      expect(biometrics.onChanged, isNull, reason: 'the app lock is off');

      vm.update((p) => p.copyWith(appLockEnabled: true));
      await tester.pumpAndSettle();

      final enabled = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings.biometrics')),
      );
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

  testWidgets('hide-addresses explains when it is for, and takes effect on save', (tester) async {
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

  group('the app-lock interval', () {
    // The Android app has always been able to configure this; the port shipped the policy without
    // the control, which left every install on the 30-second default with no way to reach it.

    testWidgets('appears only once the lock is on', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('settings.lockTimeout')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings.lockTimeout')), findsOneWidget);
      expect(find.text('Immediately'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a preset is saved under the key the Android app already writes', (tester) async {
      // `app_lock_grace_ms` is not a spelling choice: an install upgrading from the Kotlin build
      // must keep the interval it configured, and reading anything else silently reverts it.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('settings.lockTimeout.300000')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await tester.pumpAndSettle();

      expect(await repo.getSetting('app_lock_grace_ms'), '300000');
      await finish(tester);
    });

    testWidgets('a stored interval is read back into the chips', (tester) async {
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertSetting('app_lock_grace_ms', '60000');
      await pump(tester);

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('settings.lockTimeout.60000')),
      );
      expect(chip.selected, isTrue, reason: 'the saved interval must be the selected chip');
      await finish(tester);
    });

    testWidgets('editing a custom duration down to nothing does not snap to a preset', (
      tester,
    ) async {
      // The Kotlin bug (its PR #62): deleting the trailing zero from `10` momentarily gives `1`,
      // which matches the "1 min" preset. Recomputing the mode from the value alone took the text
      // field away mid-edit, so the value could not be finished.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.lockTimeout.custom')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('settings.lockTimeout.value')), '1');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings.lockTimeout.value')),
        findsOneWidget,
        reason: 'the field must survive a transient value that happens to match a preset',
      );

      await tester.enterText(find.byKey(const ValueKey('settings.lockTimeout.value')), '15');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await tester.pumpAndSettle();

      expect(await repo.getSetting('app_lock_grace_ms'), '${15 * 60 * 1000}');
      await finish(tester);
    });

    testWidgets('turning App Lock off says what it destroys, and asks', (tester) async {
      // Defect 70. Turning the lock off deletes the stored PIN and the biometric enrolment with it,
      // and Kotlin says so before saving (`ui/ToolsScreen.kt:3905`). The port went straight to the
      // save, so the destructive half of the switch was the silent one.
      await pump(tester);

      // Get it genuinely enabled and persisted first: the prompt keys off saved-vs-draft, so a
      // draft that was never saved must not trigger it.
      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await tester.pumpAndSettle();
      expect(vm.saved.appLockEnabled, isTrue);
      expect(
        find.byKey(const ValueKey('settings.appLockOff.dialog')),
        findsNothing,
        reason: 'turning it *on* must not ask',
      );

      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings.appLockOff.dialog')), findsOneWidget);
      expect(find.textContaining('deletes your saved PIN'), findsOneWidget);
      expect(find.textContaining('biometric unlock'), findsOneWidget);

      // Cancelling must leave the lock on: this is the branch that destroys the PIN.
      await tester.tap(find.byKey(const ValueKey('settings.appLockOff.cancel')));
      await tester.pumpAndSettle();
      expect(vm.saved.appLockEnabled, isTrue);

      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.appLockOff.confirm')));
      await tester.pumpAndSettle();
      expect(vm.saved.appLockEnabled, isFalse);
      await finish(tester);
    });

    testWidgets('an empty custom duration blocks Save and says why', (tester) async {
      // Saving here would keep the previous interval while the screen showed the new one.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.lockTimeout.custom')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('settings.lockTimeout.value')), '');
      await tester.pumpAndSettle();

      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('settings.save')));
      expect(save.onPressed, isNull);
      expect(find.textContaining('up to 24 hours'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('non-digits are rejected in the field, not silently dropped later', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.lockTimeout.custom')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('settings.lockTimeout.value')), '1o');
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('settings.lockTimeout.value')),
      );
      expect(field.controller!.text, '1', reason: 'the filtering must be visible in the field');
      await finish(tester);
    });
  });

  group('saving is gated behind the PIN', () {
    // Only the ungated path is covered here. Providing a live `AppLockController` stops the harness
    // settling at all — it keeps a timer for the background lock — so the gated path cannot be
    // driven through this screen without a harness rewrite larger than the fix. The gate's inputs
    // (`hasStoredPin`) are covered in `app_lock_test.dart`; the wiring is not.
    // Ported from `ui/ToolsScreen.kt:3902`. Without it, anyone holding a briefly-unlocked phone
    // could turn the app lock *off* — which clears the stored PIN outright — along with screenshot
    // blocking and sensitive-info masking. None of those should be reachable without proving you
    // can already pass the lock.

    testWidgets('with no PIN configured, Save applies straight away', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('settings.amoled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings.save')));
      await tester.pumpAndSettle();

      expect(vm.saved.amoled, isTrue);
    });
  });
}
