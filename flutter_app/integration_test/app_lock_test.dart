import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;

/// The app lock, driven end to end on a device: configure it, leave, come back, get refused, get in.
///
/// **This flow exists because §15.7 was invisible to every host test.** The lock never engaged in
/// the port, and no unit test caught it, because the defect was in the lifecycle sequence — the
/// backgrounded timestamp was overwritten by a second `paused` callback before the resume could
/// read it. Only a real background/foreground cycle on a real engine reproduces that.
///
/// It also exercises §15.12: the interval is set from the screen, which had no control at all until
/// this session, so an automated flow could not previously avoid waiting 30 real seconds.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The PIN this flow sets and clears. Fixed rather than random so a run that dies half way leaves
  /// something the next run can recognise and unlock — see [recover].
  const pin = '246810';
  const wrongPin = '999999';

  /// A bounded wait, deliberately **not** `pumpAndSettle`.
  ///
  /// `pumpAndSettle` cannot be used anywhere in this flow. A focused text field blinks its caret,
  /// which schedules a frame forever, so the wait runs to its ten-minute ceiling and the test dies
  /// having done nothing. Both text fields here are focused by the app itself: the lock screen
  /// autofocuses its PIN field, and the set-PIN dialog is typed into. Probed step by step on the
  /// device — everything up to the dialog opening settles normally, and nothing after it does.
  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }


  /// Sends the app away and brings it back, through the states Android actually delivers.
  ///
  /// Not a single jump to `paused`: the framework rejects illegal transitions, and more to the
  /// point the gate treats `inactive` and `hidden` as the start of the absence too — the app
  /// switcher shows the screen's contents to whoever is holding the phone.
  Future<void> backgroundAndReturn(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settle(tester);
  }

  /// Lays the whole of Settings out at once, so no control has to be scrolled to.
  ///
  /// Settings is thirty-odd rows in a `ListView`, which only builds what is on screen — a control
  /// further down does not merely sit off-screen, it does not exist yet. Scrolling to it worked
  /// but was fragile: `scrollUntilVisible` resolves its scrollable *each* iteration, and anything
  /// that puts a route on top (a dialog, a pushed screen) makes the list offstage, at which point
  /// the finder skips it and the scroll fails with a bare "No element".
  ///
  /// A tall surface avoids the whole class of problem, and is what `test/settings_screen_test.dart`
  /// already does for the same reason.
  void layOutWholeScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Pumps until [done], or gives up after [maxFrames].
  ///
  /// Waiting a fixed number of frames is what made this flow lie to itself: hashing a PIN is 210k
  /// PBKDF2 rounds *by design*, and on an emulator that outlasted any wait worth hard-coding. The
  /// first attempt was still verifying when the second PIN was typed, and its completion then wiped
  /// the field — so the flow submitted an empty PIN and read the resulting "Incorrect PIN" as the
  /// app rejecting a PIN it had just been given.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() done, {
    int maxFrames = 600,
  }) async {
    for (var i = 0; i < maxFrames && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  bool isLocked() => find.byKey(const ValueKey('lock.screen')).evaluate().isNotEmpty;

  /// Types [value] and waits for the attempt to actually resolve.
  ///
  /// Resolved means one of two observable things: the lock is gone, or the field has been cleared,
  /// which is what the screen does when it refuses an attempt.
  Future<void> enterPin(WidgetTester tester, String value) async {
    // Focused explicitly. `enterText` sends the text through the engine's input connection, so a
    // field that does not hold focus swallows it silently — which is what a refused attempt used
    // to leave behind, since disabling the field during verification dropped its focus.
    await tester.tap(find.byKey(const ValueKey('lock.pin')));
    await settle(tester, frames: 3);
    await tester.enterText(find.byKey(const ValueKey('lock.pin')), value);
    await settle(tester, frames: 3);
    await tester.tap(find.byKey(const ValueKey('lock.submit')));
    await pumpUntil(tester, () {
      if (!isLocked()) return true;
      final field = tester.widget<TextField>(find.byKey(const ValueKey('lock.pin')));
      return field.controller?.text.isEmpty ?? false;
    });
    await settle(tester, frames: 3);
  }

  /// Gets past the lock screen if an earlier run left one standing.
  ///
  /// A device keeps its database between runs. Without this, one failed run would leave every
  /// later run — of every suite, not just this one — staring at a lock screen it never set.
  Future<void> recover(WidgetTester tester) async {
    if (find.byKey(const ValueKey('lock.screen')).evaluate().isEmpty) return;
    await enterPin(tester, pin);
  }

  Future<void> launch(WidgetTester tester) async {
    app.main();
    // Bounded, like every other wait here. If a previous run left the app locked, the first frame
    // is the lock screen — whose PIN field autofocuses, so its caret schedules a frame forever and
    // `pumpAndSettle` runs to its ten-minute ceiling instead of returning.
    await settle(tester, frames: 30);
    await recover(tester);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nav.tools')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('tools.settings')));
    await settle(tester);
  }

  /// Puts a switch into [on], whatever it currently is.
  ///
  /// Not a blind tap. The device keeps its settings between runs, so a flow that assumes the switch
  /// starts off turns it *off* on the second run and then hunts for controls that are no longer
  /// rendered — which is exactly how this flow first failed.
  Future<void> setSwitch(WidgetTester tester, String key, {required bool on}) async {
    final finder = find.byKey(ValueKey(key));
    if (tester.widget<SwitchListTile>(finder).value == on) return;
    await tester.tap(finder);
    await settle(tester);
  }

  /// Turns the lock on with a PIN and an interval of zero, and saves.
  Future<void> enableLock(WidgetTester tester) async {
    await openSettings(tester);
    await setSwitch(tester, 'settings.appLockEnabled', on: true);

    // "Immediately", so the flow does not have to spend 30 real seconds off screen. That this chip
    // exists at all is §15.12 — the interval was unreachable before it.
    await tester.tap(find.byKey(const ValueKey('settings.lockTimeout.0')));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('settings.pin.dialog')).evaluate().isNotEmpty,
      maxFrames: 60,
    );

    // Turning the lock on has to collect a PIN — a lock with nothing to unlock it would report
    // protection it is not providing — but only when one is not already set. A run that left a PIN
    // behind is asked for nothing here, and the flow must not demand a dialog that is correctly
    // absent.
    if (find.byKey(const ValueKey('settings.pin.dialog')).evaluate().isEmpty) return;

    await tester.enterText(find.byKey(const ValueKey('settings.pin.first')), pin);
    await tester.enterText(find.byKey(const ValueKey('settings.pin.second')), pin);
    await settle(tester);
    // Hashing is 210k PBKDF2 rounds; wait for the dialog to actually close rather than guessing.
    await tester.tap(find.byKey(const ValueKey('settings.pin.confirm')));
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('settings.pin.dialog')).evaluate().isEmpty,
    );

    // The dialog closes as soon as it hands the PIN back, which is a long way from done: the save
    // it triggers still has to hash the PIN, write the settings — the interval among them — and
    // re-read them into the controller. Two signals, because either alone is too early. "Change
    // PIN" appears when the PIN is stored; the saved-confirmation card appears when the settings,
    // including the interval, have been written.
    await pumpUntil(
      tester,
      () =>
          find.byKey(const ValueKey('settings.changePin')).evaluate().isNotEmpty &&
          find.byKey(const ValueKey('settings.status')).evaluate().isNotEmpty,
    );
    // …and a moment more for the controller's own re-read, which follows the write.
    await settle(tester, frames: 10);
  }

  /// Turns the lock off and saves, which also forgets the PIN.
  Future<void> disableLock(WidgetTester tester) async {
    await openSettings(tester);
    await setSwitch(tester, 'settings.appLockEnabled', on: false);
    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await settle(tester);
  }

  testWidgets('an absence locks the app, and only the right PIN opens it', (tester) async {
    layOutWholeScreen(tester);
    await launch(tester);
    await enableLock(tester);

    // Enabling it must not lock the user out of the session they are already in.
    expect(find.byKey(const ValueKey('lock.screen')), findsNothing);

    await backgroundAndReturn(tester);
    expect(
      find.byKey(const ValueKey('lock.screen')),
      findsOneWidget,
      reason: 'a zero interval must lock on the way back — this is §15.7',
    );

    // The app underneath stays *built* on purpose — unlocking has to return the user exactly where
    // they were, including a live terminal — so its widgets are still findable. What must be true
    // is that they are inert: out of the semantics tree, unable to take focus, and untouchable.
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('nav.tools')),
        matching: find.byType(ExcludeSemantics),
      ),
      findsWidgets,
      reason: 'a screen reader must not be able to walk the app while it is locked',
    );
    await tester.tap(find.byKey(const ValueKey('nav.tools')), warnIfMissed: false);
    await settle(tester);
    expect(
      find.byKey(const ValueKey('lock.screen')),
      findsOneWidget,
      reason: 'tapping through the lock must not get anyone into the app',
    );

    await enterPin(tester, wrongPin);
    expect(find.byKey(const ValueKey('lock.error')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lock.screen')),
      findsOneWidget,
      reason: 'a wrong PIN must leave the lock standing',
    );

    await enterPin(tester, pin);
    expect(find.byKey(const ValueKey('lock.screen')), findsNothing);
    expect(find.byKey(const ValueKey('nav.tools')), findsOneWidget);

    // Left as it was found: a device that keeps the lock on would meet every later flow with a
    // screen it has no reason to expect.
    await disableLock(tester);
    await backgroundAndReturn(tester);
    expect(
      find.byKey(const ValueKey('lock.screen')),
      findsNothing,
      reason: 'turning the lock off must forget the PIN with it',
    );
  });

  testWidgets('a configuration change is not an absence', (tester) async {
    // Rotating the screen recreates the Activity on Android. Treating that as leaving the app would
    // lock the user out mid-sentence, every time they turned the phone.
    layOutWholeScreen(tester);
    await launch(tester);
    await enableLock(tester);

    tester.view.physicalSize = const Size(4200, 1200);
    await settle(tester);
    tester.view.physicalSize = const Size(1200, 4200);
    await settle(tester);

    expect(find.byKey(const ValueKey('lock.screen')), findsNothing);

    await disableLock(tester);
  });
}
