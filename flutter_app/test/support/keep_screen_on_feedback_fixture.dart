import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/shell_state.dart';
import 'package:omniterm/ui/widgets/keep_screen_on_feedback.dart';
import 'package:omniterm/ui/widgets/popup_scroll_behavior.dart';

/// The same error layout contract runs on the host and the real Flutter Android engine.
Future<void> exerciseKeepScreenOnErrorFixture(WidgetTester tester) async {
  tester.view.physicalSize = const Size(740, 380);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shell = ShellState(
    keepScreenOnSetter: (_) async {
      throw StateError(List.filled(80, 'permission refused').join(' '));
    },
  );
  addTearDown(shell.dispose);
  await shell.setKeepScreenOnDirect(true);
  await tester.pumpWidget(
    MaterialApp(
      scrollBehavior: const PopupScrollBehavior(),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(740, 380), textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SizedBox(
            height: 150,
            child: Column(
              children: [
                KeepScreenOnFeedback(shell: shell),
                const Expanded(child: Center(child: Text('Body stays usable'))),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'The global error must fit a short viewport.');
  expect(find.text('Body stays usable').hitTestable(), findsOneWidget);
  for (final action in ['retry', 'dismiss', 'details.open']) {
    expect(find.byKey(ValueKey('keepScreenOn.$action')).hitTestable(), findsOneWidget);
  }
  await tester.tap(find.byKey(const ValueKey('keepScreenOn.details.open')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('keepScreenOn.details')), findsOneWidget);
  expect(find.byKey(const ValueKey('keepScreenOn.details.message')), findsOneWidget);
  expect(
    find.text('↓ More below'),
    findsOneWidget,
    reason: 'Overflow must be visible before a drag.',
  );
  expect(find.byKey(const ValueKey('keepScreenOn.details.close')).hitTestable(), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('keepScreenOn.details.close')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('keepScreenOn.dismiss')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('keepScreenOn.error')), findsNothing);
  expect(tester.takeException(), isNull);
}
