import 'dart:typed_data';

/// Strict incremental UTF-8 decoder for arbitrary transport read boundaries.
///
/// Ported from `data/term/Utf8StreamDecoder.kt`.
///
/// Dart's built-in `utf8.decoder` also handles split sequences, but it is **not** a drop-in
/// replacement: its placement of U+FFFD for malformed input differs, and terminal output correctness
/// depends on those exact boundaries — a replacement character emitted one byte early or late
/// desynchronises the emulator's escape-sequence parser. So the hand-written decoder is ported
/// literally, including the rule below about not hoarding an incomplete prefix.
class Utf8StreamDecoder {
  static const _replacement = 0xFFFD;

  Uint8List _pending = Uint8List(0);

  void reset() => _pending = Uint8List(0);

  String decode(Uint8List bytes, {bool endOfInput = false}) {
    final Uint8List buf;
    if (_pending.isEmpty) {
      buf = bytes;
    } else {
      buf = Uint8List(_pending.length + bytes.length)
        ..setAll(0, _pending)
        ..setAll(_pending.length, bytes);
    }

    final out = StringBuffer();
    var i = 0;
    while (i < buf.length) {
      final b0 = buf[i];
      final int len;
      if (b0 < 0x80) {
        len = 1;
      } else if (b0 >= 0xC2 && b0 <= 0xDF) {
        len = 2;
      } else if (b0 >= 0xE0 && b0 <= 0xEF) {
        len = 3;
      } else if (b0 >= 0xF0 && b0 <= 0xF4) {
        len = 4;
      } else {
        len = 1;
      }

      if (len == 1) {
        out.writeCharCode(b0 < 0x80 ? b0 : _replacement);
        i++;
        continue;
      }

      // An incomplete prefix is pending only while every byte received so far is a valid
      // continuation. If an ASCII/new lead byte already disproves the sequence, emit U+FFFD now and
      // reprocess that byte instead of hiding valid terminal output indefinitely.
      final availableContinuations =
          (len - 1) < (buf.length - i - 1) ? (len - 1) : (buf.length - i - 1);
      var malformedPrefix = false;
      for (var k = 1; k <= availableContinuations; k++) {
        if ((buf[i + k] & 0xC0) != 0x80) {
          malformedPrefix = true;
          break;
        }
      }
      if (malformedPrefix) {
        out.writeCharCode(_replacement);
        i++;
        continue;
      }

      if (i + len > buf.length && !endOfInput) break;
      if (i + len > buf.length) {
        out.writeCharCode(_replacement);
        i = buf.length;
        continue;
      }

      var cp = switch (len) {
        2 => b0 & 0x1F,
        3 => b0 & 0x0F,
        _ => b0 & 0x07,
      };
      var valid = true;
      for (var k = 1; k < len; k++) {
        final next = buf[i + k];
        if ((next & 0xC0) != 0x80) {
          valid = false;
          break;
        }
        cp = (cp << 6) | (next & 0x3F);
      }
      final min = switch (len) {
        2 => 0x80,
        3 => 0x800,
        _ => 0x10000,
      };
      // Rejects overlong encodings, UTF-16 surrogates, and anything past the Unicode maximum —
      // all of which are security-relevant, not merely untidy.
      if (!valid || cp < min || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF) {
        out.writeCharCode(_replacement);
        i++; // preserve any valid byte that followed the malformed lead
      } else {
        if (cp <= 0xFFFF) {
          out.writeCharCode(cp);
        } else {
          final v = cp - 0x10000;
          out.writeCharCode(0xD800 + (v >> 10));
          out.writeCharCode(0xDC00 + (v & 0x3FF));
        }
        i += len;
      }
    }

    _pending = i < buf.length ? Uint8List.sublistView(buf, i) : Uint8List(0);
    return out.toString();
  }

  /// Flushes any held-back partial sequence, emitting U+FFFD for it.
  String finish() => decode(Uint8List(0), endOfInput: true);
}
