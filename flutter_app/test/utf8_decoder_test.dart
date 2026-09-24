import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/terminal_close.dart';
import 'package:omniterm/data/term/utf8_stream_decoder.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('Utf8StreamDecoder', () {
    test('decodes ASCII unchanged', () {
      expect(Utf8StreamDecoder().decode(bytes(utf8.encode('hello'))), 'hello');
    });

    test('reassembles a multi-byte character split across reads', () {
      // The whole point: SSH read boundaries fall wherever the network puts them.
      final decoder = Utf8StreamDecoder();
      final euro = utf8.encode('€'); // E2 82 AC
      expect(decoder.decode(bytes(euro.sublist(0, 1))), isEmpty);
      expect(decoder.decode(bytes(euro.sublist(1, 2))), isEmpty);
      expect(decoder.decode(bytes(euro.sublist(2))), '€');
    });

    test('reassembles a 4-byte emoji split byte by byte', () {
      final decoder = Utf8StreamDecoder();
      final emoji = utf8.encode('🚀');
      var out = '';
      for (final b in emoji) {
        out += decoder.decode(bytes([b]));
      }
      expect(out, '🚀');
    });

    test('emits a surrogate pair for astral characters', () {
      final decoded = Utf8StreamDecoder().decode(bytes(utf8.encode('🚀')));
      expect(decoded.codeUnits, hasLength(2));
      expect(decoded, '🚀');
    });

    test('an incomplete tail is held back, then flushed as U+FFFD by finish', () {
      final decoder = Utf8StreamDecoder();
      expect(decoder.decode(bytes([0xE2, 0x82])), isEmpty);
      expect(decoder.finish(), '�');
    });

    test('a lead byte disproved by the next byte is not hoarded', () {
      // This is the rule the Kotlin comment calls out: an ASCII byte after a truncated lead proves
      // the sequence is broken, so emit U+FFFD now rather than hiding valid terminal output until
      // some later read happens to complete it.
      final decoder = Utf8StreamDecoder();
      expect(decoder.decode(bytes([0xE2, 0x41])), '�A');
    });

    test('rejects overlong encodings', () {
      // C0 80 is an overlong NUL — a classic filter-bypass trick, not merely untidy.
      expect(Utf8StreamDecoder().decode(bytes([0xC0, 0x80])), '��');
    });

    test('rejects encoded UTF-16 surrogates', () {
      // ED A0 80 would decode to U+D800, which is not a valid scalar value.
      expect(Utf8StreamDecoder().decode(bytes([0xED, 0xA0, 0x80])), contains('�'));
    });

    test('rejects values beyond U+10FFFF', () {
      expect(Utf8StreamDecoder().decode(bytes([0xF5, 0x80, 0x80, 0x80])), contains('�'));
    });

    test('a stray continuation byte becomes one replacement character', () {
      expect(Utf8StreamDecoder().decode(bytes([0x80])), '�');
    });

    test('a valid byte after a malformed lead is preserved', () {
      final out = Utf8StreamDecoder().decode(bytes([0xC0, 0x41]));
      expect(out, endsWith('A'), reason: 'the A must not be swallowed with the bad lead');
    });

    test('reset drops any held partial sequence', () {
      final decoder = Utf8StreamDecoder()..decode(bytes([0xE2, 0x82]));
      decoder.reset();
      expect(decoder.finish(), isEmpty);
    });

    test('round-trips mixed CJK, emoji and control bytes', () {
      const text = 'ok 日本語 🚀 [31mred[0m';
      final decoder = Utf8StreamDecoder();
      final encoded = utf8.encode(text);
      // Feed in awkward 3-byte slices to force splits mid-character.
      var out = '';
      for (var i = 0; i < encoded.length; i += 3) {
        out += decoder.decode(bytes(encoded.sublist(i, (i + 3).clamp(0, encoded.length))));
      }
      out += decoder.finish();
      expect(out, text);
    });
  });

  group('classifyTerminalClose', () {
    test('a clean exit with a real status is a remote exit', () {
      final c = classifyTerminalClose(
        remoteEof: true,
        channelIsEof: true,
        sessionConnected: true,
        exitStatus: 0,
      );
      expect(c.remoteExited, isTrue);
      expect(c.exitStatus, 0);
    });

    test('a non-zero exit status is preserved', () {
      final c = classifyTerminalClose(
        remoteEof: true,
        channelIsEof: true,
        sessionConnected: true,
        exitStatus: 130,
      );
      expect(c.remoteExited, isTrue);
      expect(c.exitStatus, 130);
    });

    test('a graceful EOF on a live session normalises a missing status to 0', () {
      // The exit-status message can lag the data EOF; a clean EOF on a still-connected session is
      // a completed shell regardless.
      final c = classifyTerminalClose(
        remoteEof: true,
        channelIsEof: true,
        sessionConnected: true,
        exitStatus: -1,
      );
      expect(c.remoteExited, isTrue);
      expect(c.exitStatus, 0);
    });

    test('a network drop is NOT normalised to a clean exit', () {
      // The critical case: mistaking this for `exit` kills a session that should have reconnected,
      // and for a tmux-backed session that means abandoning still-running remote work.
      final c = classifyTerminalClose(
        remoteEof: false,
        channelIsEof: false,
        sessionConnected: false,
        exitStatus: -1,
      );
      expect(c.remoteExited, isFalse);
      expect(c.exitStatus, -1, reason: 'must stay -1 so the caller reconnects');
    });

    test('EOF without a clean channel EOF is not a remote exit', () {
      final c = classifyTerminalClose(
        remoteEof: true,
        channelIsEof: false,
        sessionConnected: false,
        exitStatus: -1,
      );
      expect(c.remoteExited, isFalse);
    });

    test('a dead session with a real status still counts as a remote exit', () {
      // The server reported a status before the transport went away, which is proof enough.
      final c = classifyTerminalClose(
        remoteEof: true,
        channelIsEof: true,
        sessionConnected: false,
        exitStatus: 0,
      );
      expect(c.remoteExited, isTrue);
      expect(c.exitStatus, 0);
    });

    test('a null status on a drop stays null', () {
      final c = classifyTerminalClose(
        remoteEof: false,
        channelIsEof: false,
        sessionConnected: true,
        exitStatus: null,
      );
      expect(c.remoteExited, isFalse);
      expect(c.exitStatus, isNull);
    });
  });
}
