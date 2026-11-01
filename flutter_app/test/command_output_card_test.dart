import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/theme/typography.dart';
import 'package:omniterm/ui/widgets/command_output_card.dart';

/// The shared remote-command output card, the inline equivalent of `ActionStreamDialog`
/// (`ui/AppUi.kt:263`).
///
/// Monitor previously rendered the same content as a bare proportional-font `Text` with no copy
/// button and no height bound: a `systemctl` failure pushed the service list off the screen and the
/// error could not be pasted anywhere. These are the properties that made that a defect.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String output = 'line one\nline two',
    String title = '',
    bool running = false,
    VoidCallback? onDismiss,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
        home: Scaffold(
          // Wrapped in a top-aligned Column so the card takes its natural height, as it does inside
          // the Infra and Monitor lists. Dropped straight into `body` it would stretch to fill the
          // screen and the height bound could not be observed.
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CommandOutputCard(
                keyPrefix: 'test.output',
                title: title,
                output: output,
                running: running,
                onDismiss: onDismiss ?? () {},
              ),
            ],
          ),
        ),
      ),
    );
    // `pump`, not `pumpAndSettle`: the running spinner animates forever and would never settle.
    await tester.pump();
  }

  testWidgets('output is monospace, because remote output is column-aligned', (tester) async {
    await pump(tester);

    final text = tester.widget<Text>(find.byKey(const ValueKey('test.output.text')));
    expect(text.style?.fontFamily, OmniFonts.mono);
  });

  testWidgets('output is selectable', (tester) async {
    // It is the text an operator pastes into a search or a bug report.
    await pump(tester);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('copying puts the whole output on the clipboard', (tester) async {
    const long = 'Job for nginx.service failed.\nSee "systemctl status nginx.service".';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester, output: long);

    await tester.tap(find.byKey(const ValueKey('test.output.copy')));
    await tester.pump();

    expect(copied, long, reason: 'a truncated copy is worse than none');
  });

  testWidgets('a long output is bounded rather than pushing the screen apart', (tester) async {
    final long = List.generate(400, (i) => 'line $i').join('\n');
    await pump(tester, output: long);

    final box = tester.getSize(find.byKey(const ValueKey('test.output')));
    expect(
      box.height,
      lessThan(300),
      reason: 'an unbounded card pushes the list it belongs to off the screen',
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('a title is shown, and falls back rather than being blank', (tester) async {
    await pump(tester, title: 'restart nginx');
    expect(find.text('restart nginx'), findsOneWidget);

    await pump(tester);
    expect(find.text('Action output'), findsOneWidget);
  });

  testWidgets('a spinner appears only while the command is still running', (tester) async {
    await pump(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await pump(tester, running: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('dismiss is reported to the caller', (tester) async {
    var dismissed = false;
    await pump(tester, onDismiss: () => dismissed = true);

    await tester.tap(find.byKey(const ValueKey('test.output.dismiss')));
    await tester.pump();

    expect(dismissed, isTrue);
  });
}
