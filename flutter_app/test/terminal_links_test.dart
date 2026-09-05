import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_snapshot.dart';
import 'package:omniterm/domain/terminal_links.dart';

TermRow _row(String text, {bool wrapped = false}) =>
    TermRow([TermSpan(text, kDefaultFg, kDefaultBg)], softWrap: wrapped);

void main() {
  test('finds http links and supplies a scheme for www links', () {
    expect(terminalLinkAt('go https://example.test/a', 8), 'https://example.test/a');
    expect(terminalLinkAt('www.example.test', 2), 'https://www.example.test');
  });

  test('trailing prose punctuation is outside the link', () {
    const line = 'see https://example.test/path).';
    expect(terminalLinkAt(line, line.indexOf('path')), 'https://example.test/path');
    expect(terminalLinkAt(line, line.length - 1), isNull);
  });

  test('a URL split across soft-wrapped rows remains tappable', () {
    final snapshot = TerminalSnapshot(
      rows: [_row('https://example.', wrapped: true), _row('test/path')],
      cursorRow: 1,
      cursorCol: 0,
      cursorVisible: true,
      cols: 16,
    );
    expect(terminalLinkAtCell(snapshot, 0, 2), 'https://example.test/path');
    expect(terminalLinkAtCell(snapshot, 1, 2), 'https://example.test/path');
  });

  test('wide glyph cells map to the same text offset', () {
    final row = TermRow([
      const TermSpan('界x', kDefaultFg, kDefaultBg, glyphs: ['界', 'x'], glyphWidths: [2, 1]),
    ]);
    expect(terminalColumnToTextOffset(row, 0), 0);
    expect(terminalColumnToTextOffset(row, 1), 0);
    expect(terminalColumnToTextOffset(row, 2), 1);
  });
}
