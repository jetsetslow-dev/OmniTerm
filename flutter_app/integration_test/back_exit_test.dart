import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;

/// Root-level back behaviour, on a device.
///
/// **The policy unit test cannot see this half.** `PopScope` is wired to the platform's back
/// dispatcher, and the defect being guarded here was in the wiring, not the rule: `canPop` was left
/// true once the in-app history emptied, so Android popped the activity itself and the app was gone
/// before any of the app's own logic ran.
///
/// Only the warn path is exercised. The other two branches end in `SystemNavigator.pop()`, which
/// would take the test host down with it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> launch(WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  /// Raises the system back gesture the way the platform does.
  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('a back press inside the app walks the screen history', (tester) async {
    await launch(tester);

    await tester.tap(find.byKey(const ValueKey('nav.tools')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen.tools')), findsOneWidget);

    await pressBack(tester);

    expect(
      find.byKey(const ValueKey('screen.tools')),
      findsNothing,
      reason: 'back must return to the previous screen before it considers exiting',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a back press at the root warns instead of exiting', (tester) async {
    await launch(tester);

    // Exactly one press. The launch screen is already the root, and a *second* press inside the
    // two-second window is the one that exits — which would take the test host down with it.
    await pressBack(tester);

    expect(
      find.text('Press back again to exit'),
      findsOneWidget,
      reason: 'a single stray back press must not take the app down with live sessions on it',
    );
    // Still running: the app is on screen, not popped.
    expect(find.byKey(const ValueKey('nav.tools')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
