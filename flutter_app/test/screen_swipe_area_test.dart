import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/widgets/screen_swipe_area.dart';

void main() {
  final swipes = <bool>[];

  Future<void> pump(WidgetTester tester, {Widget? child, VoidCallback? onSwipe}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenSwipeArea(
            onSwipe: (forward) {
              swipes.add(forward);
              onSwipe?.call();
            },
            child: child ?? const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  setUp(swipes.clear);

  for (final forward in [true, false]) {
    testWidgets('a slow paused swipe pages ${forward ? 'forward' : 'backward'} once', (
      tester,
    ) async {
      await pump(tester);
      final start = tester.getCenter(find.byType(ScreenSwipeArea));
      final direction = forward ? -1.0 : 1.0;
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(
        start + Offset(120 * direction, 0),
        timeStamp: const Duration(milliseconds: 500),
      );
      expect(swipes, [forward], reason: 'Navigation follows distance before the finger lifts');
      await gesture.moveTo(
        start + Offset(220 * direction, 0),
        timeStamp: const Duration(seconds: 1),
      );
      await gesture.moveTo(
        start + Offset(220 * direction, 0),
        timeStamp: const Duration(seconds: 2),
      );
      await gesture.up(timeStamp: const Duration(milliseconds: 2010));
      expect(swipes, [forward]);
    });
  }

  testWidgets('a short fast fling is not deliberate tab navigation', (tester) async {
    await pump(tester);
    await tester.fling(find.byType(ScreenSwipeArea), const Offset(-80, 0), 1500);
    expect(swipes, isEmpty);
  });

  testWidgets('a diagonal drag does not page until predominantly horizontal', (tester) async {
    await pump(tester);
    final start = tester.getCenter(find.byType(ScreenSwipeArea));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(start + const Offset(-130, 90));
    expect(swipes, isEmpty);
    await gesture.moveTo(start + const Offset(-230, 90));
    expect(swipes, [true]);
    await gesture.up();
  });

  testWidgets('callback rebuild and continued drag never page twice', (tester) async {
    final version = ValueNotifier(0);
    addTearDown(version.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: version,
            builder: (context, value, _) => ScreenSwipeArea(
              onSwipe: (forward) {
                swipes.add(forward);
                version.value++;
              },
              child: SizedBox.expand(child: Text('Page $value')),
            ),
          ),
        ),
      ),
    );
    final start = tester.getCenter(find.byType(ScreenSwipeArea));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(start + const Offset(-120, 0));
    await tester.pump();
    expect(find.text('Page 1'), findsOneWidget);
    await gesture.moveTo(start + const Offset(-250, 0));
    await gesture.moveTo(start + const Offset(150, 0));
    await gesture.up();
    expect(swipes, [true]);
  });

  testWidgets('cancel resets progress for the next gesture', (tester) async {
    await pump(tester);
    final start = tester.getCenter(find.byType(ScreenSwipeArea));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(start + const Offset(-80, 0));
    await gesture.cancel();
    await tester.drag(find.byType(ScreenSwipeArea), const Offset(-50, 0));
    expect(swipes, isEmpty);
    await tester.drag(find.byType(ScreenSwipeArea), const Offset(160, 0));
    expect(swipes, [false]);
  });

  for (final axis in [Axis.horizontal, Axis.vertical]) {
    testWidgets('a nested ${axis.name} scroll keeps ownership', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pump(
        tester,
        child: ListView(
          controller: controller,
          scrollDirection: axis,
          children: List.generate(12, (i) => SizedBox(width: 200, height: 200, child: Text('$i'))),
        ),
      );
      await tester.drag(
        find.byType(ListView),
        axis == Axis.horizontal ? const Offset(-240, 0) : const Offset(0, -240),
      );
      expect(controller.offset, greaterThan(0));
      expect(swipes, isEmpty);
    });
  }
}
