import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/tmux_control_commands.dart';
import 'package:omniterm/data/term/tmux_control_event.dart';
import 'package:omniterm/data/term/tmux_control_parser.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
Uint8List raw(List<int> v) => Uint8List.fromList(v);

void main() {
  group('TmuxControlParser — output', () {
    test('decodes a simple %output line', () {
      final events = TmuxControlParser().feed(b('%output %0 hello\n'));
      expect(events, hasLength(1));
      final out = events.single as TmuxOutput;
      expect(out.paneId, '%0');
      expect(utf8.decode(out.data), 'hello');
    });

    test('unescapes three-digit octal escapes', () {
      final events = TmuxControlParser().feed(b(r'%output %0 line\015\012next' '\n'));
      final out = events.single as TmuxOutput;
      expect(out.data, raw([...utf8.encode('line'), 0x0D, 0x0A, ...utf8.encode('next')]));
    });

    test('decodes an escaped ESC and backslash', () {
      final events = TmuxControlParser().feed(b(r'%output %0 \033[31m\134' '\n'));
      final out = events.single as TmuxOutput;
      expect(out.data, raw([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x5C]));
    });

    test('passes bytes >= 0x80 through raw', () {
      // The reason this parser is byte-level. Decoding to a String first would mangle every
      // multi-byte character in the pane's output.
      final line = <int>[...utf8.encode('%output %0 '), 0xE6, 0x97, 0xA5, 0x0A];
      final out = TmuxControlParser().feed(raw(line)).single as TmuxOutput;
      expect(out.data, raw([0xE6, 0x97, 0xA5]));
      expect(utf8.decode(out.data), '日');
    });

    test('a backslash not followed by three octal digits is literal', () {
      final out = TmuxControlParser().feed(b(r'%output %0 a\09b' '\n')).single as TmuxOutput;
      // \09 is not three octal digits (9 is out of range), so it stays verbatim.
      expect(utf8.decode(out.data), r'a\09b');
    });

    test('an empty payload yields empty data', () {
      final out = TmuxControlParser().feed(b('%output %3 \n')).single as TmuxOutput;
      expect(out.paneId, '%3');
      expect(out.data, isEmpty);
    });

    test('%extended-output skips reserved args up to a standalone colon', () {
      final out = TmuxControlParser()
          .feed(b('%extended-output %1 12345 : payload\n'))
          .single as TmuxOutput;
      expect(out.paneId, '%1');
      expect(utf8.decode(out.data), 'payload');
    });
  });

  group('TmuxControlParser — framing', () {
    test('reassembles a line split across chunks', () {
      final parser = TmuxControlParser();
      expect(parser.feed(b('%output %0 hel')), isEmpty);
      final out = parser.feed(b('lo\n')).single as TmuxOutput;
      expect(utf8.decode(out.data), 'hello');
    });

    test('an octal escape split across chunks still decodes', () {
      final parser = TmuxControlParser();
      expect(parser.feed(b(r'%output %0 a\01')), isEmpty);
      final out = parser.feed(b('5b\n')).single as TmuxOutput;
      expect(out.data, raw([0x61, 0x0D, 0x62]));
    });

    test('several events in one chunk are all returned', () {
      final events = TmuxControlParser().feed(b('%output %0 a\n%output %1 b\n%exit\n'));
      expect(events, hasLength(3));
      expect(events[2], const TmuxExit(null));
    });

    test('a trailing CR is stripped', () {
      final events = TmuxControlParser().feed(b('%exit bye\r\n'));
      expect(events.single, const TmuxExit('bye'));
    });
  });

  group('TmuxControlParser — replies', () {
    test('collects a %begin/%end block body', () {
      final events = TmuxControlParser().feed(
        b('%begin 1 1 0\nline one\nline two\n%end 1 1 0\n'),
      );
      expect(events.single, const TmuxReply('line one\nline two', isError: false));
    });

    test('%error marks the reply as failed', () {
      final events = TmuxControlParser().feed(b('%begin 1 1 0\nnope\n%error 1 1 0\n'));
      expect(events.single, const TmuxReply('nope', isError: true));
    });

    test('a body line starting with % is body, not a notification', () {
      // list-panes prints pane ids, so this is the normal case rather than an edge case.
      final events = TmuxControlParser().feed(
        b('%begin 1 1 0\n%0\n%1\n%end 1 1 0\n'),
      );
      expect(events, hasLength(1), reason: 'no stray notifications may escape the block');
      expect(events.single, const TmuxReply('%0\n%1', isError: false));
    });

    test('an empty body yields an empty reply', () {
      final events = TmuxControlParser().feed(b('%begin 1 1 0\n%end 1 1 0\n'));
      expect(events.single, const TmuxReply('', isError: false));
    });

    test('output arriving between replies is still decoded', () {
      final parser = TmuxControlParser();
      final events = parser.feed(b('%begin 1 1 0\nx\n%end 1 1 0\n%output %0 hi\n'));
      expect(events, hasLength(2));
      expect(utf8.decode((events[1] as TmuxOutput).data), 'hi');
    });
  });

  group('TmuxControlParser — notifications', () {
    test('parses %session-changed', () {
      final events = TmuxControlParser().feed(b(r'%session-changed $2 work' '\n'));
      expect(events.single, const TmuxSessionChanged(r'$2', 'work'));
    });

    test('a session-changed with no name yields an empty name', () {
      final events = TmuxControlParser().feed(b(r'%session-changed $2' '\n'));
      expect(events.single, const TmuxSessionChanged(r'$2', ''));
    });

    test('%exit with and without a reason', () {
      expect(TmuxControlParser().feed(b('%exit\n')).single, const TmuxExit(null));
      expect(
        TmuxControlParser().feed(b('%exit server exited\n')).single,
        const TmuxExit('server exited'),
      );
    });

    test('unknown notifications pass through verbatim', () {
      final events = TmuxControlParser().feed(b('%layout-change @0 bb62,80x24,0,0,0\n'));
      expect(events.single, const TmuxNotification('%layout-change @0 bb62,80x24,0,0,0'));
    });

    test('blank lines produce nothing', () {
      expect(TmuxControlParser().feed(b('\n\n')), isEmpty);
    });
  });

  group('TmuxControlParser — hostile input', () {
    test('an unterminated line beyond the cap is rejected', () {
      // Without this bound a remote that never sends a newline grows the buffer until the app dies.
      final parser = TmuxControlParser();
      final huge = Uint8List(TmuxControlParser.maxBufferedBytes + 1);
      expect(() => parser.feed(huge), throwsArgumentError);
    });

    test('a chunk over the cap is accepted when it contains a newline', () {
      final parser = TmuxControlParser();
      final line = <int>[...utf8.encode('%output %0 '), ...List.filled(1024, 0x61), 0x0A];
      expect(parser.feed(raw(line)), hasLength(1));
    });

    test('an oversized reply body is rejected', () {
      final parser = TmuxControlParser()..feed(b('%begin 1 1 0\n'));
      final chunk = Uint8List.fromList([...List.filled(600 * 1024, 0x61), 0x0A]);
      parser.feed(chunk);
      expect(() => parser.feed(chunk), throwsArgumentError);
    });

    test('malformed UTF-8 in a notification does not throw', () {
      final events = TmuxControlParser().feed(raw([0x25, 0x78, 0xFF, 0x0A]));
      expect(events, hasLength(1));
      expect(events.single, isA<TmuxNotification>());
    });
  });

  group('TmuxControlCommands', () {
    test('sendKeysHex encodes bytes as lowercase hex pairs', () {
      final commands = TmuxControlCommands.sendKeysHex('%0', raw([0x00, 0x1B, 0xFF]));
      expect(commands, ['send-keys -t %0 -H 00 1b ff']);
    });

    test('sendKeysHex chunks a large paste', () {
      final commands =
          TmuxControlCommands.sendKeysHex('%0', Uint8List(300), chunkSize: 128);
      expect(commands, hasLength(3), reason: '128 + 128 + 44');
    });

    test('sendKeysHex on empty data sends nothing', () {
      expect(TmuxControlCommands.sendKeysHex('%0', Uint8List(0)), isEmpty);
    });

    test('an invalid pane id is rejected everywhere it is interpolated', () {
      // These strings become tmux command lines, so an unvalidated id is command injection.
      const hostile = r'%0; kill-server';
      expect(() => TmuxControlCommands.sendKeysHex(hostile, raw([1])), throwsArgumentError);
      expect(() => TmuxControlCommands.paneOutputState(hostile, 'on'), throwsArgumentError);
      expect(
        () => TmuxControlCommands.capturePane(hostile, 100, includeScreen: true),
        throwsArgumentError,
      );
      expect(() => TmuxControlCommands.clearHistory(hostile), throwsArgumentError);
      expect(() => TmuxControlCommands.sendKeysHex('pane0', raw([1])), throwsArgumentError);
    });

    test('an invalid pane output state is rejected', () {
      expect(() => TmuxControlCommands.paneOutputState('%0', 'wat'), throwsArgumentError);
    });

    test('paneOutputState escapes the leading % of a colon-qualified id', () {
      // tmux 3.3a parses a bare `%0:pause` as syntax and aborts our init with a parse error.
      expect(TmuxControlCommands.paneOutputState('%0', 'pause'), r'refresh-client -A \%0:pause');
    });

    test('refreshClientSize clamps to at least 1x1', () {
      expect(TmuxControlCommands.refreshClientSize(80, 24), 'refresh-client -C 80x24');
      expect(TmuxControlCommands.refreshClientSize(0, -5), 'refresh-client -C 1x1');
    });

    test('capturePane includes or excludes the visible screen', () {
      expect(
        TmuxControlCommands.capturePane('%0', 5000, includeScreen: true),
        'capture-pane -p -e -J -S -5000 -t %0',
      );
      expect(
        TmuxControlCommands.capturePane('%0', 5000, includeScreen: false),
        'capture-pane -p -e -J -S -5000 -E -1 -t %0',
        reason: 'history only, or the visible rows are duplicated',
      );
    });

    test('capturePane clamps a negative history depth', () {
      expect(
        TmuxControlCommands.capturePane('%0', -10, includeScreen: true),
        contains('-S -0'),
      );
    });
  });
}
