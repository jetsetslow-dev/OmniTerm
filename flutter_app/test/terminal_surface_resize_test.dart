import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';
import 'package:omniterm/ui/theme/terminal_theme.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';
import 'package:omniterm/ui/widgets/terminal_surface.dart';

import 'support/fake_terminal_session.dart';

void main() {
  const palette = TerminalPalette(
    background: Colors.black,
    foreground: Colors.white,
    cursor: Colors.white,
  );

  ShellSession session(FakeTerminalSession channel, String id) => ShellSession(
    id: id,
    serverId: 7,
    serverName: 'fixture',
    channel: channel,
    emulator: TerminalEmulator(cols: 80, rows: 24, scrollbackLimit: 2000),
  );

  Future<void> show(
    WidgetTester tester,
    ShellSession session,
    double width, {
    double height = 300,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: TerminalSurface(session: session, fontSize: 10, palette: palette),
          ),
        ),
      ),
    ),
  );

  test('remote grids retain Kotlin limits even on a very large canvas', () {
    const metrics = TerminalMetrics(cellWidth: 10, cellHeight: 10, fontSize: 10);
    expect(metrics.gridFor(const Size(10000, 10000)), (500, 300));
    expect(metrics.gridFor(Size.zero), (1, 1));
  });

  testWidgets('a resize waits for 120ms and replaces unsettled dimensions', (tester) async {
    final channel = FakeTerminalSession();
    final terminal = session(channel, 'one');
    addTearDown(() async {
      terminal.dispose();
      await channel.dispose();
    });
    await show(tester, terminal, 400);
    expect(channel.resizes, isEmpty, reason: 'Kotlin waits for layout to settle before reflow');
    await tester.pump(const Duration(milliseconds: 120));
    expect(channel.resizes, [(37, 29)]);

    await show(tester, terminal, 450);
    await tester.pump(const Duration(milliseconds: 119));
    expect(channel.resizes, hasLength(1));
    await show(tester, terminal, 470);
    await tester.pump(const Duration(milliseconds: 119));
    expect(channel.resizes, hasLength(1), reason: 'the newest layout restarts the wait');
    await tester.pump(const Duration(milliseconds: 1));
    expect(channel.resizes, [(37, 29), (43, 29)]);
  });

  testWidgets('removing the surface cancels its pending remote resize', (tester) async {
    final channel = FakeTerminalSession();
    final terminal = session(channel, 'one');
    addTearDown(() async {
      terminal.dispose();
      await channel.dispose();
    });
    await show(tester, terminal, 400);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 120));
    expect(channel.resizes, isEmpty);
  });

  testWidgets('visible rows update before the remote grid settles', (tester) async {
    final channel = FakeTerminalSession();
    final terminal = session(channel, 'one')..publishNow();
    addTearDown(() async {
      terminal.dispose();
      await channel.dispose();
    });
    await show(tester, terminal, 400, height: 130);
    expect(terminal.viewportRows, 12);
    expect(terminal.snapshot.rows, hasLength(12));
    expect(terminal.rows, 24, reason: 'local viewport changes must not reflow the remote grid');
    expect(channel.resizes, isEmpty);
    await tester.pump(const Duration(milliseconds: 120));
    expect(channel.resizes, [(37, 12)]);
  });

  testWidgets('switching sessions cancels the previous pane resize', (tester) async {
    final firstChannel = FakeTerminalSession();
    final secondChannel = FakeTerminalSession();
    final first = session(firstChannel, 'one');
    final second = session(secondChannel, 'two');
    addTearDown(() async {
      first.dispose();
      second.dispose();
      await firstChannel.dispose();
      await secondChannel.dispose();
    });
    await show(tester, first, 400);
    await show(tester, second, 470);
    await tester.pump(const Duration(milliseconds: 120));
    expect(firstChannel.resizes, isEmpty);
    expect(secondChannel.resizes, [(43, 29)]);
  });

  testWidgets('unsettled terminal columns stay inside their pane', (tester) async {
    final channel = FakeTerminalSession();
    final terminal = session(channel, 'one');
    terminal.emulator.feed(Uint8List.fromList(List.filled(80, 'X').join().codeUnits));
    terminal.publishNow();
    addTearDown(() async {
      terminal.dispose();
      await channel.dispose();
    });
    const boundaryKey = ValueKey('pane.frame');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 100,
                height: 40,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Positioned.fill(child: ColoredBox(color: Colors.red)),
                    Positioned(
                      left: 0,
                      top: 0,
                      width: 50,
                      height: 40,
                      child: TerminalSurface(session: terminal, fontSize: 10, palette: palette),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
    final pixel = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData())!;
      final offset = (8 * image.width + 60) * 4;
      final color = Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      ).toARGB32();
      image.dispose();
      return color;
    });
    await tester.pumpWidget(const SizedBox.shrink());
    expect(pixel, Colors.red.toARGB32(), reason: 'the adjacent pane must not receive stale text');
  });
}
