import 'package:flutter_test/flutter_test.dart';

import 'package:omniterm/domain/tui_scroll_router.dart';

void main() {
  void expectPages(TuiScrollAction action, bool up, int count) {
    expect(action, isA<PageTuiScroll>());
    expect((action as PageTuiScroll).up, up);
    expect(action.count, count);
  }

  test('buffers the gesture while alternate-screen state is unknown', () {
    final router = TuiScrollRouter();
    expect(router.isIdle, isTrue);
    expect(router.onDelta(40, 100), isA<BufferedTuiScroll>());
    expect(router.awaitingResolution, isTrue);
    expect(router.isIdle, isFalse);
  });

  test('a plain shell receives the complete buffered gesture once', () {
    final router = TuiScrollRouter();
    router.onDelta(40, 100);
    router.onDelta(25, 100);
    final action = router.resolve(tuiActive: false, pageSize: 100) as LocalTuiScroll;
    expect(action.delta, 65);
    expect((router.onDelta(10, 100) as LocalTuiScroll).delta, 10);
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 0);
    expect((router.onDelta(-5, 100) as LocalTuiScroll).delta, -5);
  });

  test('a TUI pages the buffered gesture and carries its fractional remainder', () {
    final router = TuiScrollRouter();
    router.onDelta(150, 100);
    router.onDelta(100, 100);
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 2);
    expect(router.routedToTui, isTrue);
    expectPages(router.onDelta(50, 100), true, 1);
  });

  test('upward drags send PageDown', () {
    final router = TuiScrollRouter();
    router.onDelta(-10, 100);
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 0);
    expectPages(router.onDelta(-95, 100), false, 1);
  });

  test('small drags accumulate without sending premature keys', () {
    final router = TuiScrollRouter();
    router.onDelta(10, 100);
    router.resolve(tuiActive: true, pageSize: 100);
    expectPages(router.onDelta(30, 100), true, 0);
    expectPages(router.onDelta(30, 100), true, 0);
    expectPages(router.onDelta(40, 100), true, 1);
  });

  test('reversing direction consumes the remainder before paging', () {
    final router = TuiScrollRouter();
    router.onDelta(60, 100);
    router.resolve(tuiActive: true, pageSize: 100);
    expectPages(router.onDelta(-60, 100), true, 0);
    expectPages(router.onDelta(-100, 100), false, 1);
  });

  test('a fling emits at most three pages per event and discards excess pages', () {
    for (final direction in [1.0, -1.0]) {
      final router = TuiScrollRouter();
      router.onDelta(1050 * direction, 100);
      expectPages(router.resolve(tuiActive: true, pageSize: 100), direction > 0, 3);
      expectPages(router.onDelta(0, 100), true, 0);
      expectPages(router.onDelta(50 * direction, 100), direction > 0, 1);
    }
  });

  test('reset drops buffered pixels, the chosen route and partial pages', () {
    final router = TuiScrollRouter();
    router.onDelta(80, 100);
    router.reset();
    expect(router.isIdle, isTrue);
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 0);
    expect(router.onDelta(10, 100), isA<BufferedTuiScroll>());
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 0);
    router.reset();
    router.onDelta(90, 100);
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 0);
  });

  test('resolving without a pending gesture leaves an idle router unchanged', () {
    final router = TuiScrollRouter();
    expectPages(router.resolve(tuiActive: true, pageSize: 100), true, 0);
    expect(router.isIdle, isTrue);
  });

  test('a zero-sized viewport never divides by zero', () {
    final router = TuiScrollRouter();
    router.onDelta(5, 0);
    expectPages(router.resolve(tuiActive: true, pageSize: 0), true, 3);
  });
}
