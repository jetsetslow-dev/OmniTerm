import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/code_highlighter.dart';
import 'package:omniterm/ui/widgets/code_editor.dart';

void main() {
  testWidgets('shows a line-number gutter and defaults to unwrapped editing', (
    tester,
  ) async {
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
            child: CodeEditor(
              controller: controller,
              language: CodeLanguage.none,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('codeEditor.line.1')), findsOneWidget);
    expect(find.byKey(const ValueKey('codeEditor.line.3')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('codeEditor.wrap')))
          .tooltip,
      'Word wrap: off',
    );
  });

  testWidgets('word-wrap toggle changes mode without changing the document', (
    tester,
  ) async {
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
            child: CodeEditor(
              controller: controller,
              language: CodeLanguage.none,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('codeEditor.wrap')));
    await tester.pump();

    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('codeEditor.wrap')))
          .tooltip,
      'Word wrap: on',
    );
    expect(
      controller.text,
      'a very long logical line that should remain intact',
    );
  });
}
