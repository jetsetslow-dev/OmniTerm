import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';
import 'package:omniterm/ui/theme/terminal_theme.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';
import 'package:omniterm/ui/widgets/terminal_surface.dart';

import 'support/fake_terminal_session.dart';

void main() {
  late FakeTerminalSession channel;
  late ShellSession session;
  final pages = <(bool, int)>[];
  var queries = 0;
  var scrollbackRequests = 0;

  setUp(() {
    channel = FakeTerminalSession();
    session = ShellSession(
      id: 's1',
      serverId: 7,
      serverName: 'nas',
      channel: channel,
      emulator: TerminalEmulator(cols: 80, rows: 24, scrollbackLimit: 2000),
    );
    pages.clear();
    queries = 0;
    scrollbackRequests = 0;
  });

  tearDown(() async {
    session.dispose();
    await channel.dispose();
  });

  Future<void> show(WidgetTester tester, {required bool tuiActive}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: TerminalSurface(
              session: session,
              palette: const TerminalPalette(
                background: Colors.black,
                foreground: Colors.white,
                cursor: Colors.white,
              ),
              queryTuiActive: () async {
                queries++;
                return tuiActive;
              },
              sendTuiPages: (up, count) {
                pages.add((up, count));
                return true;
              },
              onScrolledBack: () => scrollbackRequests++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> drag(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('shell.surface'))),
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(Offset(0, dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  testWidgets('a live TUI receives page keys without moving local history', (tester) async {
    await show(tester, tuiActive: true);
    expect(session.followTail, isTrue);

    await drag(tester, 500);

    expect(queries, 1);
    expect(pages, [(true, 1)]);
    expect(session.followTail, isTrue);
    expect(scrollbackRequests, 0);
  });

  testWidgets('a plain shell receives the buffered drag as local history', (tester) async {
    await show(tester, tuiActive: false);
    for (var i = 0; i < 100; i++) {
      channel.emit('line $i\r\n');
    }
    await tester.pump(const Duration(milliseconds: 40));
    expect(session.followTail, isTrue);

    await drag(tester, 200);

    expect(queries, 1);
    expect(pages, isEmpty);
    expect(session.followTail, isFalse);
    expect(scrollbackRequests, 0, reason: 'a raw shell has no tmux history to fetch');
  });

  testWidgets('history already off the live tail stays local', (tester) async {
    await show(tester, tuiActive: true);
    for (var i = 0; i < 100; i++) {
      channel.emit('line $i\r\n');
    }
    await tester.pump(const Duration(milliseconds: 40));
    session.scrollBy(-3);
    await tester.pump();
    expect(session.followTail, isFalse);

    await drag(tester, 80);

    expect(queries, 0);
    expect(pages, isEmpty);
    expect(session.followTail, isFalse);
  });

  testWidgets('a shell swipe keeps moving through history after the finger lifts', (tester) async {
    await show(tester, tuiActive: false);
    for (var i = 0; i < 200; i++) {
      channel.emit('line $i\r\n');
    }
    await tester.pump(const Duration(milliseconds: 40));

    await tester.fling(find.byKey(const ValueKey('shell.surface')), const Offset(0, 90), 900);
    final atLift = session.viewportFirstRow;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(session.viewportFirstRow, lessThan(atLift));
  });

  testWidgets('a short TUI swipe can page during its fling', (tester) async {
    await show(tester, tuiActive: true);

    await tester.fling(find.byKey(const ValueKey('shell.surface')), const Offset(0, 90), 5000);
    expect(pages, isEmpty, reason: 'the touch distance alone is shorter than a page');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(pages, isNotEmpty);
    expect(pages.every((page) => page.$1), isTrue);
    expect(session.followTail, isTrue);
  });
}
