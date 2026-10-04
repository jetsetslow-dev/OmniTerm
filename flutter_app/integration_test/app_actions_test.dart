import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:provider/provider.dart';

/// Actions, on a device — not screens.
///
/// The other two device suites open every destination and check it renders. That catches a screen
/// that crashes on a real engine, and nothing else: **an action that writes to the database, opens
/// a dialog and comes back can still fail on a device while every widget test passes**, which is
/// how an ICU-only regex defect in the Compose Builder reached a release.
///
/// Everything here runs without a reachable host, deliberately. The flows that need one belong in
/// the lab suites; these are the actions a user can perform on a plane, and they
/// are the ones that persist state, so a failure here is data loss rather than a blank pane.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> launch(WidgetTester tester) async {
    // A tall surface, so no control has to be scrolled to.
    //
    // These flows reached their controls with `scrollUntilVisible(..., scrollable: Scrollable.first)`,
    // which is two guesses: that the first scrollable is the one holding the target, and that it
    // survives the drag. On a Galaxy S23 (411x882 logical) the alert-rules flow failed with a bare
    // `Bad state: No element` from inside `dragUntilVisible` — the scrollable it had picked was gone
    // by the time it dragged. `app_lock_test.dart` and `crash_log_test.dart` already avoid the whole
    // class this way, and a device flow should be testing the app, not the test's scroll heuristics.
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.main();
    // The database opens, settings load and the host stream emits, all asynchronously. A flow that
    // starts before those land is driving a screen the user never sees.
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  Future<void> goTo(WidgetTester tester, Screen screen) async {
    final destination = find.byKey(ValueKey('nav.${screen.name}'));
    await tester.ensureVisible(destination);
    await tester.tap(destination);
    await tester.pumpAndSettle();
  }

  /// Reads a switch by key, scrolling to it first for the same reason [tapKey] does.
  Future<bool> switchValue(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }
    return tester.widget<Switch>(finder).value;
  }

  /// Taps [key], scrolling to it first.
  ///
  /// Long screens are `ListView`s, so a control below the fold is not merely off-screen — it has
  /// not been built, and `ensureVisible` cannot reach a widget that does not exist yet. Every
  /// failure of this helper on the first attempt was that, not a missing key.
  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    if (finder.evaluate().isEmpty) {
      final scrollable = find.byType(Scrollable);
      if (scrollable.evaluate().isNotEmpty) {
        await tester.scrollUntilVisible(finder, 200, scrollable: scrollable.first);
        await tester.pumpAndSettle();
      }
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('quick scripts', () {
    testWidgets('a script survives being created, and the list shows it', (tester) async {
      // A create that appears to work and writes nothing is indistinguishable from one that works,
      // until the app is reopened. This drives the real editor against the real database.
      await launch(tester);
      await goTo(tester, Screen.tools);
      await tapKey(tester, 'tools.quickScripts');

      await tapKey(tester, 'scripts.add');
      expect(find.byKey(const ValueKey('scripts.editor.form')), findsOneWidget);

      final name = 'device-check-${DateTime.now().millisecondsSinceEpoch}';
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), name);
      await tester.enterText(
        find.byKey(const ValueKey('scripts.editor.command')),
        'echo device-check',
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'scripts.editor.save');

      expect(
        find.text(name),
        findsWidgets,
        reason: 'the saved script is not in the list the user is looking at',
      );

      // Leave and come back: the list is rebuilt from the database rather than from what the
      // editor happened to leave in memory.
      await goTo(tester, Screen.servers);
      await goTo(tester, Screen.tools);
      await tapKey(tester, 'tools.quickScripts');
      expect(
        find.text(name),
        findsWidgets,
        reason: 'the script did not survive leaving the screen',
      );
    });
  });

  group('settings', () {
    testWidgets('enabling App Lock opens PIN setup and Cancel leaves it disabled', (tester) async {
      // Kotlin configures the PIN immediately, before any unrelated Settings drafts are saved.
      await launch(tester);
      await goTo(tester, Screen.tools);
      await tapKey(tester, 'tools.settings');

      await tapKey(tester, 'settings.appLockEnabled');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings.pin.dialog')),
        findsOneWidget,
        reason: 'a lock with no PIN behind it would be no lock at all',
      );

      // Cancel: the switch must not be left on and unbacked, which would show a lock that cannot
      // engage.
      await tapKey(tester, 'settings.pin.cancel');
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byKey(const ValueKey('settings.appLockEnabled'))).value,
        isFalse,
        reason: 'cancelling the PIN left the lock switched on with nothing behind it',
      );
    });

    // The native phone-sized Settings actions fixture also exercises PIN configuration,
    // authenticated saving and the confirmation/authentication order for removing the PIN.

    testWidgets('a changed setting is written and read back', (tester) async {
      // Settings that appear to save and do not are the quietest failure in the app: the screen
      // shows the new value and the app keeps using the old one.
      await launch(tester);
      await goTo(tester, Screen.tools);
      await tapKey(tester, 'tools.settings');

      await tapKey(tester, 'settings.blockScreenshots');
      final toggled = await switchValue(tester, 'settings.blockScreenshots');
      await tapKey(tester, 'settings.save');
      await tester.pumpAndSettle();

      await goTo(tester, Screen.servers);
      await goTo(tester, Screen.tools);
      await tapKey(tester, 'tools.settings');

      expect(
        await switchValue(tester, 'settings.blockScreenshots'),
        toggled,
        reason: 'the saved value did not survive leaving the screen',
      );

      // Put it back, so the suite is re-runnable on a device that keeps its data.
      await tapKey(tester, 'settings.blockScreenshots');
      await tapKey(tester, 'settings.save');
      expect(find.byKey(const ValueKey('settings.save.progress')), findsNothing);
      expect(find.byKey(const ValueKey('settings.save.error')), findsNothing);
      expect(find.text('Settings saved.'), findsOneWidget);
    });
  });

  group('alert rules', () {
    testWidgets('a rule can be created, then deleted again', (tester) async {
      // Alert rules are the one thing in the app that acts on its own, so a rule that appears to
      // save and does not is a monitor that silently watches nothing. Both halves are driven here:
      // a create that is not verified, and a delete that is not verified, hide opposite defects.
      await launch(tester);
      await goTo(tester, Screen.tools);
      await tapKey(tester, 'tools.alerts');
      await tapKey(tester, 'alerts.tab.rules');

      final before = find.byKey(const ValueKey('alerts.rules.empty')).evaluate().isNotEmpty;
      await tapKey(tester, 'alerts.addRule');
      await tester.enterText(find.byKey(const ValueKey('alerts.editor.threshold')), '93');
      await tester.pumpAndSettle();

      final save = find.byKey(const ValueKey('alerts.editor.save'));
      final row = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('alerts.rule.') &&
            (w.key! as ValueKey<String>).value.endsWith('.delete'),
      );
      final previousRuleKeys = row.evaluate().map((element) => element.widget.key).toSet();
      await tester.ensureVisible(save);
      await tester.tap(save);
      // A pump can settle before SQLite and its rule stream publish the save. The list exists
      // behind the sheet and the unsaved threshold is still visible in its text field, so neither
      // is proof that the write finished. Wait for both the sheet to close and its row to render.
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (save.evaluate().isEmpty && row.evaluate().isNotEmpty) break;
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(save, findsNothing, reason: 'the editor did not finish saving the rule');

      expect(
        find.byKey(const ValueKey('alerts.rules.list')),
        findsOneWidget,
        reason: 'the rule list is still empty after saving a rule',
      );
      expect(
        find.textContaining('93'),
        findsWidgets,
        reason: 'the saved threshold is not the one on screen',
      );

      // Delete it again, so the suite leaves the device as it found it and the delete path is
      // exercised rather than assumed.
      expect(row, findsWidgets, reason: 'no rule row to delete');
      final createdKey = row
          .evaluate()
          .map((element) => element.widget.key)
          .singleWhere((key) => !previousRuleKeys.contains(key));
      final createdRow = find.byKey(createdKey!);
      await tester.tap(createdRow);
      await tester.pumpAndSettle();
      await tapKey(tester, 'alerts.deleteRule.confirm');
      // SQLite and its stream finish outside animation settling. Wait for this exact row's
      // removal, then check the resulting list; never delete a pre-existing fixture rule.
      for (var attempt = 0; attempt < 100 && createdRow.evaluate().isNotEmpty; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(createdRow, findsNothing, reason: 'the created rule was not removed');

      if (before) {
        expect(
          find.byKey(const ValueKey('alerts.rules.empty')),
          findsOneWidget,
          reason: 'the rule was not removed',
        );
      }
    });
  });

  group('hosts', () {
    testWidgets('a failed automatic host check still offers direct SSH', (tester) async {
      // The whole app is empty without this, and it is the one flow every other screen depends on.
      await launch(tester);
      await goTo(tester, Screen.servers);
      final context = tester.element(find.byKey(const ValueKey('screen.servers')));
      final appState = context.read<AppState>();
      final hostProbe = context.read<HostStatusProbe>()..stop();
      addTearDown(hostProbe.stop);
      await tapKey(tester, 'servers.add');

      final name = 'device-host-${DateTime.now().millisecondsSinceEpoch}';
      await tester.enterText(find.byKey(const ValueKey('serverForm.name')), name);
      await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '127.0.0.1');
      await tester.enterText(find.byKey(const ValueKey('serverForm.port')), '1');
      await tester.enterText(find.byKey(const ValueKey('serverForm.username')), 'root');
      await tester.pumpAndSettle();
      await tapKey(tester, 'serverForm.test');
      expect(find.byKey(const ValueKey('serverForm.testResult')), findsOneWidget);
      await tapKey(tester, 'serverForm.save');
      expect(find.byKey(const ValueKey('serverForm.unverified.dialog')), findsOneWidget);
      await tapKey(tester, 'serverForm.unverified.saveAnyway');

      expect(find.text(name), findsWidgets, reason: 'the saved host is not in the list');

      // A fresh host is deliberately not called unreachable before anything has tried it. Trigger
      // the real production probe against a repository-controlled refused endpoint; this exercises
      // both the cheap TCP attempt and the authoritative SSH fallback without relying on a lab.
      for (
        var attempt = 0;
        attempt < 20 && !appState.servers.any((server) => server.name == name);
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final saved = appState.servers.singleWhere((server) => server.name == name);
      await tester.runAsync(() => hostProbe.probeOne(saved));
      await tester.pumpAndSettle();

      expect(
        find.text('AUTOMATIC SSH CHECK FAILED'),
        findsOneWidget,
        reason: 'an advisory probe failure must be described as a check failure, not certainty',
      );
      expect(
        find.text('SSH ANYWAY'),
        findsOneWidget,
        reason: 'a failed automatic check must never remove the user\'s direct SSH path',
      );

      // A launcher may be slow to acknowledge dynamic shortcut updates. The SSH decision must
      // reach the user while that independent platform call is still outstanding.
      const shortcutChannel = MethodChannel('omniterm/shortcuts');
      final shortcutReleased = Completer<bool>();
      final shortcutInvoked = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(shortcutChannel, (call) async {
        if (call.method == 'pushServer') {
          shortcutInvoked.complete();
          return shortcutReleased.future;
        }
        return true;
      });
      addTearDown(() {
        if (!shortcutReleased.isCompleted) shortcutReleased.complete(true);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(shortcutChannel, null);
      });

      await tester.tap(find.text('SSH ANYWAY'));
      await tester.pumpAndSettle();
      expect(shortcutInvoked.isCompleted, isTrue);
      expect(find.byKey(const ValueKey('offline.connect.dialog')), findsOneWidget);
      shortcutReleased.complete(true);
      await tapKey(tester, 'offline.connect.confirm');
      for (
        var attempt = 0;
        attempt < 100 && find.byKey(const ValueKey('shell.error')).evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const ValueKey('shell.error')),
        findsOneWidget,
        reason: 'the refused real SSH attempt must explain why it returned to the shell page',
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('shell.host.label.${saved.id}')),
          matching: find.text(name),
        ),
        findsOneWidget,
        reason: 'the header must identify the failed target above its connection prompt',
      );
      expect(find.text('Retry'), findsOneWidget, reason: 'the failed attempt must be retryable');
    });
  });
}
