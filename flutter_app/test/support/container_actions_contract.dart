import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared by ordinary widget regression and the disposable Android runtime exercise.
Future<void> openContainerAction(
  WidgetTester tester, {
  required String runtime,
  required String id,
  required String action,
  bool confirm = true,
}) async {
  final menu = find.byKey(ValueKey('infra.container.$runtime.$id.menu'));
  expect(menu, findsOneWidget, reason: 'Each replica needs its own container action menu');
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
  final item = find.byWidgetPredicate(
    (widget) => widget is PopupMenuItem<String> && widget.value == action,
  );
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
  final dialog = find.byKey(ValueKey('infra.container.$runtime.$id.$action.confirm'));
  expect(dialog, findsOneWidget);
  expect(find.descendant(of: dialog, matching: find.text('Cancel')).hitTestable(), findsOneWidget);
  await tester.tap(
    find.descendant(
      of: dialog,
      matching: confirm ? find.byType(FilledButton) : find.widgetWithText(TextButton, 'Cancel'),
    ),
  );
  await tester.pump();
}
