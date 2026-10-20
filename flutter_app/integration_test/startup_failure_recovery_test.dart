import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/ui/widgets/startup_recovery_app.dart';

/// A release build normally replaces a build exception with an unhelpful blank/grey surface.
///
/// This is device coverage rather than another host-only widget assertion because the regression
/// was reported on a Samsung API 36 release install. It proves that the independent recovery UI
/// can become the root Android surface without relying on OmniTerm's providers, database or theme.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a startup build exception renders an actionable recovery screen', (tester) async {
    final previous = ErrorWidget.builder;
    ErrorWidget.builder = startupRecoveryForError;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (_) => throw StateError('device startup failure probe')),
        ),
      );
      expect(tester.takeException(), isA<StateError>());
      await tester.pump();

      expect(find.byKey(const ValueKey('startup.recovery')), findsOneWidget);
      expect(find.text('OmniTerm could not start'), findsOneWidget);
      expect(find.textContaining('device startup failure probe'), findsOneWidget);
      expect(find.byKey(const ValueKey('startup.recovery.clear')), findsOneWidget);
      expect(find.byKey(const ValueKey('startup.recovery.copy')), findsOneWidget);
    } finally {
      ErrorWidget.builder = previous;
    }
  });
}
