import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';
import 'package:omniterm/ui/theme/terminal_theme.dart';
import 'package:omniterm/ui/theme/text_scaling.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';
import 'package:omniterm/ui/widgets/terminal_surface.dart';

import 'support/fake_terminal_session.dart';

void main() {
  testWidgets('terminal grid follows system text size but not the app text preset', (tester) async {
    final channel = FakeTerminalSession();
    final session = ShellSession(
      id: 's1',
      serverId: 7,
      serverName: 'nas',
      channel: channel,
      emulator: TerminalEmulator(cols: 80, rows: 24, scrollbackLimit: 2000),
    );
    addTearDown(() async {
      session.dispose();
      await channel.dispose();
    });
    final grids = <(int, int)>[];

    Future<(int, int)> show({required double systemScale, required double appScale}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: OmniTextScaler(TextScaler.linear(systemScale), appScale),
            ),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: TerminalSurface(
                    session: session,
                    fontSize: 10,
                    palette: const TerminalPalette(
                      background: Colors.black,
                      foreground: Colors.white,
                      cursor: Colors.white,
                    ),
                    onGridChanged: (cols, rows) => grids.add((cols, rows)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return grids.last;
    }

    final normal = await show(systemScale: 1, appScale: .92);
    final largeSystem = await show(systemScale: 1.5, appScale: .92);
    final largeApp = await show(systemScale: 1.5, appScale: 1.1);

    expect(largeSystem.$1, lessThan(normal.$1), reason: 'larger Android text needs fewer columns');
    expect(largeSystem.$2, lessThan(normal.$2), reason: 'larger Android text needs fewer rows');
    expect(
      largeApp,
      largeSystem,
      reason: 'Kotlin sizes terminal cells from sp, not app text preset',
    );
  });

  testWidgets('Android cells use physical pixel widths and unrounded font bounds', (tester) async {
    final channel = FakeTerminalSession();
    final session = ShellSession(
      id: 's1',
      serverId: 7,
      serverName: 'fixture',
      channel: channel,
      emulator: TerminalEmulator(cols: 80, rows: 24, scrollbackLimit: 2000),
    );
    addTearDown(() async {
      session.dispose();
      await channel.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2.625),
          child: SizedBox(
            width: 400,
            height: 300,
            child: TerminalSurface(
              session: session,
              fontSize: 10.3,
              palette: const TerminalPalette(
                background: Colors.black,
                foreground: Colors.white,
                cursor: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const ValueKey('shell.surface')),
        matching: find.byType(CustomPaint),
      ),
    );
    final metrics = (paint.painter! as TerminalPainter).metrics;
    // Ahem has a one-em M advance and one-em ascent. Android Paint rounds the advance
    // in physical pixels, but retains fractional font bounds for the row height.
    expect(metrics.cellWidth * 2.625, closeTo(27, .00001));
    expect(metrics.cellHeight, closeTo(10.3, .00001));
  });
}
