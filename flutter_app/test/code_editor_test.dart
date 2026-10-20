import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/code_highlighter.dart';
import 'package:omniterm/ui/widgets/code_editor.dart';

void main() {
  Future<HighlightEditingController> pumpEditor(
    WidgetTester tester, {
    String text = 'one\ntwo\nthree',
    CodeLanguage language = CodeLanguage.none,
    Size size = const Size(500, 400),
    double textScale = 1,
    bool readOnly = false,
    int maxHighlightChars = 1000,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = HighlightEditingController(
      text: text,
      language: language,
      maxChars: maxHighlightChars,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SizedBox(
              width: size.width,
              height: size.height,
              child: CodeEditor(
                controller: controller,
                language: language,
                readOnly: readOnly,
                maxHighlightChars: maxHighlightChars,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('shows a line-number gutter and defaults to unwrapped editing', (tester) async {
    final controller = HighlightEditingController(
      text: 'one\ntwo\nthree',
      language: CodeLanguage.none,
      maxChars: 1000,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 400,
            child: CodeEditor(controller: controller, language: CodeLanguage.none),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('codeEditor.line.1')), findsOneWidget);
    expect(find.byKey(const ValueKey('codeEditor.line.3')), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('codeEditor.wrap'))).tooltip,
      'Word wrap: off',
    );
  });

  testWidgets('word-wrap toggle changes mode without changing the document', (tester) async {
    final controller = HighlightEditingController(
      text: 'a very long logical line that should remain intact',
      language: CodeLanguage.none,
      maxChars: 1000,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 300,
            child: CodeEditor(controller: controller, language: CodeLanguage.none),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('codeEditor.wrap')));
    await tester.pump();

    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('codeEditor.wrap'))).tooltip,
      'Word wrap: on',
    );
    expect(controller.text, 'a very long logical line that should remain intact');
  });

  testWidgets('syntax colours render through the editing controller and stop past the limit', (
    tester,
  ) async {
    final controller = await pumpEditor(
      tester,
      text: 'image: "nginx" # web',
      language: CodeLanguage.yaml,
      maxHighlightChars: 100,
    );
    final context = tester.element(find.byKey(const ValueKey('codeEditor.text')));

    final highlighted = controller.buildTextSpan(
      context: context,
      style: const TextStyle(),
      withComposing: false,
    );
    expect(highlighted.children, isNotEmpty);
    expect(
      highlighted.children!.whereType<TextSpan>().any((span) => span.style?.color != null),
      isTrue,
    );

    controller.maxChars = controller.text.length - 1;
    final plain = controller.buildTextSpan(
      context: context,
      style: const TextStyle(),
      withComposing: false,
    );
    expect(plain.text, controller.text);
    expect(plain.children, isNull);
  });

  testWidgets('find, case-sensitive regex and replace-all operate on the real document', (
    tester,
  ) async {
    final controller = await pumpEditor(tester, text: 'Foo foo FOO');
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'foo');
    await tester.enterText(find.byKey(const ValueKey('codeEditor.replacement')), 'bar');
    await tester.tap(find.byKey(const ValueKey('codeEditor.replaceAll')));
    await tester.pump();
    expect(controller.text, 'bar bar bar');

    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), '[');
    await tester.tap(find.widgetWithText(FilterChip, '.*'));
    await tester.pump();
    expect(find.text('Invalid pattern'), findsOneWidget);
  });

  testWidgets('Replace leaves a hand-made selection alone when the query matches nothing', (
    tester,
  ) async {
    final controller = await pumpEditor(tester, text: 'keep this line');
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'absent');
    await tester.enterText(find.byKey(const ValueKey('codeEditor.replacement')), 'gone');
    await tester.pump();

    // The selection a user makes by dragging, not one the search produced.
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();

    final replace = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Replace'));
    expect(replace.onPressed, isNull, reason: 'no matches, so Replace must be disabled');
    expect(controller.text, 'keep this line');
  });

  testWidgets('Replace rewrites the match the search selected', (tester) async {
    final controller = await pumpEditor(tester, text: 'keep this line');
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'this');
    await tester.enterText(find.byKey(const ValueKey('codeEditor.replacement')), 'that');
    await tester.pump();

    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Replace'));
    await tester.pump();

    expect(controller.text, 'keep that line');
  });

  testWidgets('Replace rewrites the found match, never a hand-made selection', (tester) async {
    // Kotlin's rule: Replace acts on the current match (the first at or after the cursor), so it
    // can only ever rewrite text the search found, whatever the user has selected by hand.
    final controller = await pumpEditor(tester, text: 'keep this line');
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'this');
    await tester.enterText(find.byKey(const ValueKey('codeEditor.replacement')), 'that');
    await tester.pump();

    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codeEditor.replace')));
    await tester.pump();

    expect(controller.text, 'keep that line', reason: '"keep" was selected but not found');
  });

  testWidgets('the match count reads current/total, as in Kotlin', (tester) async {
    final controller = await pumpEditor(tester, text: 'a b a b a');
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();
    String count() =>
        tester.widget<Text>(find.byKey(const ValueKey('codeEditor.matchCount'))).data!;
    expect(count(), '');

    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'a');
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(count(), '1/3');
    await tester.tap(find.byKey(const ValueKey('codeEditor.next')));
    await tester.pump();
    expect(count(), '2/3');
    await tester.tap(find.byKey(const ValueKey('codeEditor.previous')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codeEditor.previous')));
    await tester.pump();
    expect(count(), '3/3', reason: 'previous wraps around');

    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'zzz');
    await tester.pump();
    expect(count(), '0/0');
  });

  testWidgets('a read-only editor shows Replace but cannot use it', (tester) async {
    final controller = await pumpEditor(tester, text: 'keep this line', readOnly: true);
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('codeEditor.query')), 'this');
    await tester.pump();

    TextButton button(String key) => tester.widget<TextButton>(find.byKey(ValueKey(key)));
    expect(button('codeEditor.replace').onPressed, isNull);
    expect(button('codeEditor.replaceAll').onPressed, isNull);
    expect(controller.text, 'keep this line');
  });

  testWidgets('go-to-line moves the selection to the requested line start', (tester) async {
    final controller = await pumpEditor(tester, text: 'line1\nline2\nline3');
    await tester.enterText(find.byKey(const ValueKey('codeEditor.goToLine')), '3');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codeEditor.goToLine.go')));
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 12));

    // Past the end: the start of the last line, not the end of the buffer.
    await tester.enterText(find.byKey(const ValueKey('codeEditor.goToLine')), '99');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codeEditor.goToLine.go')));
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 12));
  });

  testWidgets('the editor and find controls do not clip on a 360dp phone at 200% text', (
    tester,
  ) async {
    await pumpEditor(tester, size: const Size(360, 720), textScale: 2);
    await tester.tap(find.byKey(const ValueKey('codeEditor.find')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('codeEditor.query')), findsOneWidget);
    expect(find.byKey(const ValueKey('codeEditor.replacement')), findsOneWidget);
  });
}
