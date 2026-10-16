import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_snapshot.dart';
import 'package:omniterm/ui/theme/terminal_theme.dart';
import 'package:omniterm/ui/widgets/terminal_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const metrics = TerminalMetrics(cellWidth: 20, cellHeight: 12, fontSize: 10, fontFamily: 'Ahem');
  const palette = TerminalPalette(
    background: Colors.black,
    foreground: Colors.white,
    cursor: Colors.white,
  );

  Future<int Function(int, int)> render(
    TermSpan span, {
    bool cursor = false,
    int cursorCol = 0,
    TerminalMetrics geometry = metrics,
  }) async {
    final recorder = ui.PictureRecorder();
    TerminalPainter(
      snapshot: TerminalSnapshot(
        rows: [
          TermRow([span]),
        ],
        cursorRow: 0,
        cursorCol: cursorCol,
        cursorVisible: cursor,
        cols: 4,
      ),
      metrics: geometry,
      palette: palette,
      showCursor: cursor,
    ).paint(Canvas(recorder), const Size(80, 12));
    final picture = recorder.endRecording();
    final image = await picture.toImage(80, 12);
    final bytes = (await image.toByteData())!;
    image.dispose();
    picture.dispose();
    return (x, y) {
      final offset = (y * 80 + x) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      ).toARGB32();
    };
  }

  test('glyphs keep their cell centers when font advances differ from cell width', () async {
    final pixel = await render(
      const TermSpan('AB', kDefaultFg, kDefaultBg, glyphs: ['A', 'B'], glyphWidths: [1, 1]),
    );
    expect(pixel(10, 5), Colors.white.toARGB32());
    expect(pixel(20, 5), Colors.black.toARGB32(), reason: 'space between cell-centered glyphs');
    expect(pixel(30, 5), Colors.white.toARGB32(), reason: 'second glyph stays in its own cell');
  });

  test('wide glyphs are centered across their two cells', () async {
    final pixel = await render(
      const TermSpan('AB', kDefaultFg, kDefaultBg, glyphs: ['A', 'B'], glyphWidths: [2, 1]),
    );
    expect(pixel(20, 5), Colors.white.toARGB32());
    expect(pixel(50, 5), Colors.white.toARGB32());
  });

  test('glyphs follow the font baseline rather than the rounded paragraph top', () async {
    final pixel = await render(
      const TermSpan('A', kDefaultFg, kDefaultBg),
      geometry: const TerminalMetrics(
        cellWidth: 20,
        cellHeight: 12,
        fontSize: 10,
        fontFamily: 'Ahem',
        baselineOffset: 6,
      ),
    );
    expect(pixel(10, 5), Colors.white.toARGB32());
    expect(pixel(10, 9), Colors.black.toARGB32(), reason: 'glyph follows the requested baseline');
  });

  test('the cursor fills its cell with an opaque block', () async {
    final pixel = await render(const TermSpan(' ', kDefaultFg, kDefaultBg), cursor: true);
    expect(pixel(1, 1), Colors.white.toARGB32());
  });

  test('the cursor keeps its underlying glyph readable', () async {
    final pixel = await render(
      const TermSpan('A', kDefaultFg, kDefaultBg, glyphs: ['A'], glyphWidths: [1]),
      cursor: true,
    );
    expect(pixel(1, 1), Colors.white.toARGB32());
    expect(pixel(10, 5), Colors.black.toARGB32());
  });

  test('a cursor on a wide continuation clips the glyph at its original center', () async {
    final pixel = await render(
      const TermSpan('A', kDefaultFg, kDefaultBg, glyphs: ['A'], glyphWidths: [2]),
      cursor: true,
      cursorCol: 1,
    );
    expect(pixel(17, 5), Colors.white.toARGB32(), reason: 'outside the cursor is unchanged');
    expect(pixel(23, 5), Colors.black.toARGB32(), reason: 'original glyph overlaps the cursor');
    expect(pixel(30, 5), Colors.white.toARGB32(), reason: 'glyph must not shift into continuation');
  });
}
