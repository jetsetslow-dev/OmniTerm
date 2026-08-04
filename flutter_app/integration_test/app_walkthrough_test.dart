import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/ui/navigation.dart';

/// End-to-end flows against the real app, on a device (requirement 6, §11).
///
/// **These exist because the widget tests cannot see what a device does.** Everything here has a
/// counterpart among the defects the manual device walk found: a screen that renders in a widget
/// test but crashes on a real engine (§15.9), state that is never written so every screen reads as
/// empty (§15.8), a lifecycle sequence no unit test replays (§15.7). Automating the walk is how
/// those stop being things somebody has to remember to check by hand.
///
/// Written against the `ValueKey`s every screen carries by convention 1, which is exactly what that
/// convention was for.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Boots the real app and waits for the first frame to settle.
  Future<void> launch(WidgetTester tester) async {
    app.main();
    // `pumpAndSettle` alone is not enough at launch: the database opens, settings load and the host
    // stream emits, all asynchronously, and a flow that starts before those land is testing a
    // screen the user never sees.
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  Future<void> goTo(WidgetTester tester, Screen screen) async {
    await tester.tap(find.byKey(ValueKey('nav.${screen.name}')));
    await tester.pumpAndSettle();
  }

  group('the app comes up', () {
    testWidgets('every primary destination renders without throwing', (tester) async {
      // The manual walk that found §15.9 was exactly this, done by hand with adb taps.
      await launch(tester);

      for (final screen in [
        Screen.servers,
        Screen.fleet,
        Screen.monitor,
        Screen.shell,
        Screen.sftp,
        Screen.infra,
        Screen.tools,
      ]) {
        await goTo(tester, screen);
        expect(tester.takeException(), isNull, reason: '${screen.name} threw while rendering');
      }
    });

    testWidgets('no screen is ever merely blank', (tester) async {
      // An empty list is not a fact, it is the absence of one — the rule §15.10 and the Infra empty
      // states came out of. A blank screen and a broken screen look identical to a user.
      //
      // Deliberately written to hold whether or not the device already has hosts saved: a flow that
      // assumes a pristine install passes once and then fails for whoever runs it next, which is
      // the device equivalent of the host-dependence trap in §19.
      await launch(tester);

      for (final screen in [Screen.servers, Screen.shell, Screen.monitor, Screen.fleet]) {
        await goTo(tester, screen);
        expect(
          find.byType(Text),
          findsWidgets,
          reason: '${screen.name} rendered nothing a user could read',
        );
      }
    });
  });

  group('Tools', () {
    testWidgets('every tool is reachable from the hub', (tester) async {
      await launch(tester);
      await goTo(tester, Screen.tools);

      for (final (screen, _, _) in [
        (Screen.alerts, '', ''),
        (Screen.quickScripts, '', ''),
        (Screen.network, '', ''),
        (Screen.authKeys, '', ''),
        (Screen.backup, '', ''),
        (Screen.healthScoring, '', ''),
        (Screen.settings, '', ''),
        (Screen.about, '', ''),
      ]) {
        await goTo(tester, Screen.tools);
        await tester.tap(find.byKey(ValueKey('tools.${screen.name}')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${screen.name} threw');
      }
    });

    testWidgets('About reports a real version, not the fallback', (tester) async {
      // `PackageInfo` needs a platform channel. In widget tests it always throws and the screen
      // shows "Version …", so the *working* path had never once been executed before a device run.
      await launch(tester);
      await goTo(tester, Screen.tools);
      await tester.tap(find.byKey(const ValueKey('tools.about')));
      await tester.pumpAndSettle();

      final version = tester.widget<Text>(find.byKey(const ValueKey('about.version'))).data!;
      expect(version, isNot(contains('…')), reason: 'PackageInfo did not resolve');
      expect(version, contains('build'));
    });

    testWidgets('the diagnostics block carries nothing identifying', (tester) async {
      // Asserted on a real device because that is where the platform strings actually come from —
      // the host-test version can only check a stub.
      await launch(tester);
      await goTo(tester, Screen.tools);
      await tester.tap(find.byKey(const ValueKey('tools.about')));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.byKey(const ValueKey('about.diagnostics.text'))).data!;
      expect(text, contains('Platform:'));
      expect(text, isNot(contains('@')), reason: 'no user@host may appear');
    });
  });

  group('adding a host', () {
    testWidgets('an untested host is not offered as ready to save', (tester) async {
      // Driving this by hand is what put a password into a display-name field twice; a flow does
      // not mis-tap.
      await launch(tester);
      await goTo(tester, Screen.servers);

      await tester.tap(find.byKey(const ValueKey('servers.add')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('serverForm.tabs')), findsOneWidget);

      // Typed through the framework rather than `adb shell input text`, which mangles anything with
      // a space or a newline and lands it in whichever field happens to hold focus — how a password
      // ended up in a display-name field during the manual walk.
      await tester.enterText(find.byKey(const ValueKey('serverForm.name')), 'flow-host');
      await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '203.0.113.1');
      await tester.pumpAndSettle();

      // The button's own label is the gate: an untested host reads "Save (test first)", and only
      // a passing connection test turns it into a plain "Save". That is the behaviour worth
      // pinning — a host saved without ever having connected is the thing this prevents.
      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('serverForm.save')));
      expect(
        (save.child! as Text).data,
        'Save (test first)',
        reason: 'a host that has never connected must not look ready to save',
      );
      expect(tester.takeException(), isNull);

      // Closed without saving: a flow must not leave a host behind for the next run.
      await tester.tap(find.byKey(const ValueKey('serverForm.close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('serverForm.tabs')), findsNothing);
    });
  });
}
