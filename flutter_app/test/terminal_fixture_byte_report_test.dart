import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';

import '../integration_test/support/terminal_byte_report.dart';

void main() {
  test('held-key byte reports retain byte boundaries across terminal wrap widths', () {
    const token = '1234567890123456';
    final expected = [
      for (var i = 0; i < 6; i++) ...[27, 91, 65],
    ];
    // This is the repository fixture's od output with whitespace encoded as commas. Leading,
    // trailing and former newline separators remain nonblank cells when a row is trimmed.
    final report = 'KEYBAR_$token:,${expected.join(',')},:END_$token\r\n';
    for (var cols = 8; cols <= 80; cols++) {
      final terminal = TerminalEmulator(cols: cols, rows: 24, scrollbackLimit: 100);
      terminal.feed(Uint8List.fromList(utf8.encode(report)));
      final output = terminal.snapshot().rows.map((row) => row.text).join();
      expect(readTerminalFixtureBytes(output, token), expected, reason: '$cols columns');
    }
  });
}
