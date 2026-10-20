import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/shell_state.dart';
import 'package:omniterm/ui/widgets/keep_screen_on_feedback.dart';
import 'package:omniterm/ui/widgets/omni_chrome.dart';

import 'support/keep_screen_on_feedback_fixture.dart';

void main() {
  testWidgets(
    'a short viewport keeps error details and recovery actions reachable',
    exerciseKeepScreenOnErrorFixture,
  );

  testWidgets('progress remains visible until acknowledgment and retry reports its result', (
    tester,
  ) async {
    final first = Completer<void>();
    final retry = Completer<void>();
    var calls = 0;
    final shell = ShellState(keepScreenOnSetter: (_) => ++calls == 1 ? first.future : retry.future);
    addTearDown(shell.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(children: [KeepScreenOnFeedback(shell: shell)]),
        ),
      ),
    );
    final operation = shell.setKeepScreenOnDirect(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('keepScreenOn.progress')), findsOneWidget);
    expect(find.text('Enabling Keep screen on…'), findsOneWidget);
    expect(shell.isKeepScreenOnEnabled, isFalse);
    first.completeError(StateError('platform unavailable'));
    await operation;
    await tester.pump();
    expect(find.byKey(const ValueKey('keepScreenOn.progress')), findsNothing);
    expect(find.textContaining('platform unavailable'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keepScreenOn.retry')));
    await tester.pump();
    expect(find.byKey(const ValueKey('keepScreenOn.progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('keepScreenOn.error')), findsNothing);
    retry.complete();
    await tester.pump();
    expect(shell.isKeepScreenOnEnabled, isTrue);
    expect(find.byKey(const ValueKey('keepScreenOn.progress')), findsNothing);
    expect(find.byKey(const ValueKey('keepScreenOn.error')), findsNothing);
  });

  testWidgets('error actions stay reachable at large text scale and can be dismissed', (
    tester,
  ) async {
    final shell = ShellState(
      keepScreenOnSetter: (_) async => throw StateError('permission refused'),
    );
    addTearDown(shell.dispose);
    await shell.setKeepScreenOnDirect(true);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(width: 320, child: KeepScreenOnFeedback(shell: shell)),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('keepScreenOn.retry')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('keepScreenOn.dismiss')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keepScreenOn.dismiss')));
    await tester.pump();
    expect(find.byKey(const ValueKey('keepScreenOn.error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the app bar disables pending Keep screen on work', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: OmniAppBar(
            activeColor: Colors.blue,
            alertCount: 0,
            keepScreenOn: false,
            onHome: () {},
            onAlerts: () {},
            onToggleKeepScreenOn: null,
          ),
        ),
      ),
    );
    final action = find.widgetWithIcon(IconButton, Icons.lightbulb);
    expect(tester.widget<IconButton>(action).onPressed, isNull);
  });
}
