import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/widgets/startup_recovery_app.dart';

/// The screen shown instead of the app when the last launch crashed while starting.
void main() {
  testWidgets('it builds without the app it replaces', (tester) async {
    // The point of the screen: it runs when the real app could not be built, so it must not need
    // providers, a database or a theme controller. Pumped bare for exactly that reason.
    await tester.pumpWidget(
      const StartupRecoveryApp(report: 'Bad state: database is locked'),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('startup.recovery')), findsOneWidget);
    expect(find.text('OmniTerm could not start'), findsOneWidget);
  });

  testWidgets('the report is shown so it can be read and sent on', (tester) async {
    await tester.pumpWidget(
      const StartupRecoveryApp(report: 'Bad state: database is locked'),
    );
    await tester.pump();

    expect(find.textContaining('database is locked'), findsOneWidget);
  });

  testWidgets('it promises the data is untouched, before the button is pressed', (tester) async {
    // "Clear" next to a crash report could as easily mean wiping the app's data, which is the thing
    // the user is most afraid of at this moment.
    await tester.pumpWidget(const StartupRecoveryApp(report: 'boom'));
    await tester.pump();

    expect(find.textContaining('not touched'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup.recovery.clear')), findsOneWidget);
    expect(find.byKey(const ValueKey('startup.recovery.copy')), findsOneWidget);
  });
}
