import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/widgets/popup_scroll_behavior.dart';

void main() {
  testWidgets('overflowing popup menus retain item taps and show scroll cues', (tester) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const PopupScrollBehavior(),
        home: Scaffold(
          body: PopupMenuButton<int>(
            onSelected: (value) => selected = value,
            itemBuilder: (_) =>
                List.generate(40, (i) => PopupMenuItem(value: i, child: Text('Item $i'))),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    expect(find.text('↓ More below'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Item 39'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('↑ More above'), findsOneWidget);
    await tester.tap(find.text('Item 39'));
    await tester.pumpAndSettle();
    expect(selected, 39);
    expect(find.text('↑ More above'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final sheet in [false, true]) {
    for (final direction in AxisDirection.values) {
      final vertical = axisDirectionToAxis(direction) == Axis.vertical;
      final reverse = direction == AxisDirection.up || direction == AxisDirection.left;
      String label(AxisDirection value) => switch (value) {
        AxisDirection.up => '↑ More above',
        AxisDirection.down => '↓ More below',
        AxisDirection.left => '← More left',
        AxisDirection.right => '→ More right',
      };
      final before = label(flipAxisDirection(direction));
      final after = label(direction);
      testWidgets('${sheet ? 'sheet' : 'dialog'} $direction indicates overflow and resize', (
        tester,
      ) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final contentHeight = ValueNotifier<double>(1000);
        addTearDown(contentHeight.dispose);
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const PopupScrollBehavior(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    final content = SizedBox(
                      height: 200,
                      width: 250,
                      child: SingleChildScrollView(
                        scrollDirection: axisDirectionToAxis(direction),
                        reverse: reverse,
                        controller: controller,
                        child: ValueListenableBuilder<double>(
                          valueListenable: contentHeight,
                          builder: (_, height, _) => SizedBox(
                            height: vertical ? height : 30,
                            width: vertical ? 100 : height,
                            child: const Text('Content'),
                          ),
                        ),
                      ),
                    );
                    if (sheet) {
                      showModalBottomSheet<void>(context: context, builder: (_) => content);
                    } else {
                      showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(content: content),
                      );
                    }
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text(after), findsOneWidget);
        expect(find.text(before), findsNothing);
        controller.jumpTo(100);
        await tester.pumpAndSettle();
        expect(find.text(after), findsOneWidget);
        expect(find.text(before), findsOneWidget);
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text(after), findsNothing);
        expect(find.text(before), findsOneWidget);
        contentHeight.value = 20;
        await tester.pumpAndSettle();
        expect(find.text(after), findsNothing);
        expect(find.text(before), findsNothing);
        contentHeight.value = 1000;
        await tester.pumpAndSettle();
        expect(find.text(after), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
