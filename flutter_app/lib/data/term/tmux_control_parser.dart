import 'dart:convert';
import 'dart:typed_data';

import 'tmux_control_event.dart';

/// Incremental parser for the tmux control-mode wire protocol, ported from `TmuxControlParser` in
/// `data/term/TmuxControl.kt`.
///
/// Protocol facts below were verified against real `tmux -C` output from tmux 3.3a:
///  - Command replies are wrapped in `%begin <ts> <num> <flags>` … `%end|%error <ts> <num> <flags>`.
///    Body lines are arbitrary text and **may themselves start with `%`** (`list-panes` prints pane
///    ids), so while inside a block only `%end`/`%error` terminate it.
///  - `%output %<pane> <data>`: control bytes and backslash are escaped as exactly three octal
///    digits (`\015\012` for CRLF, `\033` for ESC, `\134` for backslash); bytes ≥ 0x80 (UTF-8
///    continuation bytes) pass through **raw** — so parsing must be byte-level, never through a
///    String decode. Decoding to a String first would mangle every multi-byte character.
///  - Other notifications (`%session-changed`, `%layout-change`, …) are single lines; `%exit [reason]`
///    ends the conversation.
class TmuxControlParser {
  /// Bound on both the unterminated tail and a single reply body.
  ///
  /// This is a denial-of-service guard, not tidiness: without it a remote that never sends a newline
  /// grows the buffer until the app dies. Kept from the Kotlin deliberately.
  static const maxBufferedBytes = 1024 * 1024;

  static const _nl = 0x0A;
  static const _cr = 0x0D;
  static const _sp = 0x20;
  static const _backslash = 0x5C;
  static const _colon = 0x3A;
  static const _zero = 0x30;
  static const _seven = 0x37;

  static final _outputPrefix = Uint8List.fromList(ascii.encode('%output '));
  static final _extendedOutputPrefix = Uint8List.fromList(ascii.encode('%extended-output '));

  Uint8List _pending = Uint8List(0);
  bool _inReply = false;
  final StringBuffer _replyBody = StringBuffer();

  /// Feed raw bytes from the control-mode channel; returns the events completed by this chunk.
  List<TmuxControlEvent> feed(Uint8List chunk) {
    if (_pending.length + chunk.length > maxBufferedBytes && !chunk.contains(_nl)) {
      throw ArgumentError('tmux control line exceeds $maxBufferedBytes bytes');
    }

    final events = <TmuxControlEvent>[];
    final Uint8List buf;
    if (_pending.isEmpty) {
      buf = chunk;
    } else {
      buf = Uint8List(_pending.length + chunk.length)
        ..setAll(0, _pending)
        ..setAll(_pending.length, chunk);
    }

    var start = 0;
    for (var i = 0; i < buf.length; i++) {
      if (buf[i] == _nl) {
        _handleLine(buf, start, i, events);
        start = i + 1;
      }
    }

    _pending = start >= buf.length ? Uint8List(0) : Uint8List.sublistView(buf, start);
    if (_pending.length > maxBufferedBytes) {
      throw ArgumentError('tmux control line exceeds $maxBufferedBytes bytes');
    }
    return events;
  }

  void _handleLine(Uint8List buf, int start, int end, List<TmuxControlEvent> out) {
    // Strip a trailing CR: tmux itself terminates lines with a bare \n, but be lenient.
    final e = (end > start && buf[end - 1] == _cr) ? end - 1 : end;

    if (_inReply) {
      // Inside a reply block everything except the terminator is body — including lines that start
      // with '%', which list-panes output does.
      final text = _decode(buf, start, e);
      if (text.startsWith('%end ')) {
        _inReply = false;
        out.add(TmuxReply(_replyBody.toString(), isError: false));
      } else if (text.startsWith('%error ')) {
        _inReply = false;
        out.add(TmuxReply(_replyBody.toString(), isError: true));
      } else {
        if (_replyBody.length + text.length + 1 > maxBufferedBytes) {
          throw ArgumentError('tmux control reply exceeds $maxBufferedBytes characters');
        }
        if (_replyBody.isNotEmpty) _replyBody.write('\n');
        _replyBody.write(text);
      }
      return;
    }

    if (_matchesPrefix(buf, start, e, _outputPrefix)) {
      var i = start + _outputPrefix.length;
      final paneStart = i;
      while (i < e && buf[i] != _sp) {
        i++;
      }
      final paneId = _decode(buf, paneStart, i);
      final dataStart = i < e ? i + 1 : e;
      out.add(TmuxOutput(paneId, _unescapeOctal(buf, dataStart, e)));
      return;
    }

    if (_matchesPrefix(buf, start, e, _extendedOutputPrefix)) {
      var i = start + _extendedOutputPrefix.length;
      final paneStart = i;
      while (i < e && buf[i] != _sp) {
        i++;
      }
      final paneId = _decode(buf, paneStart, i);
      // Arguments reserved for future tmux versions end at a standalone ':' token.
      var dataStart = e;
      while (i < e) {
        while (i < e && buf[i] == _sp) {
          i++;
        }
        if (i < e && buf[i] == _colon && (i + 1 == e || buf[i + 1] == _sp)) {
          dataStart = i + 1 < e ? i + 2 : e;
          break;
        }
        while (i < e && buf[i] != _sp) {
          i++;
        }
      }
      out.add(TmuxOutput(paneId, _unescapeOctal(buf, dataStart, e)));
      return;
    }

    final text = _decode(buf, start, e);
    if (text.startsWith('%begin ')) {
      _inReply = true;
      _replyBody.clear();
    } else if (text.startsWith('%session-changed ')) {
      final rest = text.substring('%session-changed '.length);
      final space = rest.indexOf(' ');
      final id = space < 0 ? rest : rest.substring(0, space);
      final name = space < 0 ? '' : rest.substring(space + 1);
      out.add(TmuxSessionChanged(id, name));
    } else if (text == '%exit' || text.startsWith('%exit ')) {
      final reason = text.substring('%exit'.length).trim();
      out.add(TmuxExit(reason.isEmpty ? null : reason));
    } else if (text.isNotEmpty) {
      out.add(TmuxNotification(text));
    }
  }

  /// Decode `%output` payload: `\NNN` (exactly three octal digits) → byte; everything else verbatim.
  ///
  /// Anything that is not a complete three-digit escape is copied through untouched, which is what
  /// keeps raw UTF-8 continuation bytes intact.
  Uint8List _unescapeOctal(Uint8List buf, int from, int to) {
    final out = Uint8List(to - from);
    var n = 0;
    var i = from;
    while (i < to) {
      final b = buf[i];
      if (b == _backslash &&
          i + 3 < to &&
          _isOctal(buf[i + 1]) &&
          _isOctal(buf[i + 2]) &&
          _isOctal(buf[i + 3])) {
        out[n++] = ((buf[i + 1] - _zero) << 6) | ((buf[i + 2] - _zero) << 3) | (buf[i + 3] - _zero);
        i += 4;
      } else {
        out[n++] = b;
        i++;
      }
    }
    return n == out.length ? out : Uint8List.sublistView(out, 0, n);
  }

  static bool _isOctal(int b) => b >= _zero && b <= _seven;

  static bool _matchesPrefix(Uint8List buf, int start, int end, Uint8List prefix) {
    if (end - start < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (buf[start + i] != prefix[i]) return false;
    }
    return true;
  }

  /// Kotlin's `decodeToString` replaces malformed input rather than throwing; `allowMalformed`
  /// matches that. A control line with one bad byte must not kill the session.
  static String _decode(Uint8List buf, int start, int end) =>
      utf8.decode(Uint8List.sublistView(buf, start, end), allowMalformed: true);
}
