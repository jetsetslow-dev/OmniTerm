import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared by the ordinary missing-menu regression and the repository SSH fixture on Android.
void expectTerminalOptionsReady(WidgetTester tester) {
  expect(find.text('Terminal input'), findsOneWidget);
  expect(find.text('Paste from clipboard').hitTestable(), findsOneWidget);
  expect(find.text('This session'), findsOneWidget);
  expect(find.text('Swipe-typing'), findsOneWidget);
  expect(find.text('Keep screen on'), findsOneWidget);
  expect(find.byKey(const ValueKey('terminalOptions.visible')).hitTestable(), findsOneWidget);
  expect(find.byKey(const ValueKey('terminalOptions.full')).hitTestable(), findsOneWidget);
}
