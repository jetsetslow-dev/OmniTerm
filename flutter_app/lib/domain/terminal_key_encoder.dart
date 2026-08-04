import 'dart:convert';
import 'dart:typed_data';

/// The terminal keys the special-key bar and a hardware keyboard can send.
///
/// Ported from `TermKey` in `ui/AppViewModel.kt`.
enum TermKey {
  enter,
  backspace,
  tab,
  esc,
  up,
  down,
  left,
  right,
  home,
  end,
  insert,
  delete,
  pageUp,
  pageDown,
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  f7,
  f8,
  f9,
  f10,
  f11,
  f12,
}

/// Input policy shared by terminal UI implementations, including a future iOS presentation.
///
/// Only paging is allowed while a session is read-only: it moves the viewport without sending
/// anything to the remote host.
bool terminalKeyAllowedInReadOnly(TermKey key) =>
    key == TermKey.pageUp || key == TermKey.pageDown;

/// Pure xterm-compatible encoder shared by hardware and on-screen terminal keys.
///
/// Ported from `ui/TerminalKeyEncoder.kt`.
abstract final class TerminalKeyEncoder {
  /// The control byte a Ctrl-chord produces, or null when the chord has no encoding.
  static int? controlByte(int codePoint) {
    const space = 0x20, at = 0x40, two = 0x32;
    const a = 0x61, z = 0x7A, upperA = 0x41, upperZ = 0x5A;

    if (codePoint == space || codePoint == at || codePoint == two) return 0x00;
    if (codePoint >= a && codePoint <= z) return codePoint - a + 1;
    if (codePoint >= upperA && codePoint <= upperZ) return codePoint - upperA + 1;

    return switch (codePoint) {
      0x5B => 0x1B, // [
      0x5C => 0x1C, // \
      0x5D => 0x1D, // ]
      0x5E || 0x36 => 0x1E, // ^ or 6
      0x5F || 0x2F => 0x1F, // _ or /
      0x3F => 0x7F, // ?
      _ => null,
    };
  }

  /// Encodes [key] into the bytes an xterm-compatible host expects.
  ///
  /// [applicationCursorKeys] is the DECCKM mode: when a full-screen application has enabled it, the
  /// cursor keys use SS3 (`ESC O A`) rather than CSI (`ESC [ A`). Modified cursor keys always use
  /// the CSI form with a modifier parameter, which is what xterm itself does.
  static Uint8List encode(
    TermKey key, {
    required bool applicationCursorKeys,
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    // xterm's modifier encoding: 1 + shift(1) + alt(2) + ctrl(4).
    final mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);

    // Both sequences are introduced by ESC (0x1B): CSI is "ESC [", SS3 is "ESC O".
    Uint8List csi(String value) => _ascii('\u001B[$value');
    Uint8List ss3(String letter) => _ascii('\u001BO$letter');

    Uint8List cursor(String letter) {
      if (mod > 1) return csi('1;$mod$letter');
      if (applicationCursorKeys) return ss3(letter);
      return csi(letter);
    }

    Uint8List tilde(int code) => csi(mod > 1 ? '$code;$mod~' : '$code~');
    Uint8List f1ToF4(String letter) => mod > 1 ? csi('1;$mod$letter') : ss3(letter);

    // Alt is sent as an ESC prefix on the keys that have no modifier parameter of their own.
    Uint8List altPrefix(List<int> base) =>
        Uint8List.fromList(alt ? [0x1B, ...base] : base);

    return switch (key) {
      TermKey.enter => altPrefix(const [0x0D]),
      TermKey.backspace => altPrefix(const [0x7F]),
      TermKey.tab => shift
          ? csi('Z')
          : (alt ? Uint8List.fromList(const [0x1B, 0x09]) : Uint8List.fromList(const [0x09])),
      TermKey.esc => Uint8List.fromList(alt ? const [0x1B, 0x1B] : const [0x1B]),
      TermKey.up => cursor('A'),
      TermKey.down => cursor('B'),
      TermKey.right => cursor('C'),
      TermKey.left => cursor('D'),
      TermKey.home => cursor('H'),
      TermKey.end => cursor('F'),
      TermKey.insert => tilde(2),
      TermKey.delete => tilde(3),
      TermKey.pageUp => tilde(5),
      TermKey.pageDown => tilde(6),
      TermKey.f1 => f1ToF4('P'),
      TermKey.f2 => f1ToF4('Q'),
      TermKey.f3 => f1ToF4('R'),
      TermKey.f4 => f1ToF4('S'),
      TermKey.f5 => tilde(15),
      TermKey.f6 => tilde(17),
      TermKey.f7 => tilde(18),
      TermKey.f8 => tilde(19),
      TermKey.f9 => tilde(20),
      TermKey.f10 => tilde(21),
      TermKey.f11 => tilde(23),
      TermKey.f12 => tilde(24),
    };
  }
}

/// Encodes typed text under the sticky Ctrl/Alt/Shift modifiers, ported from `typeText` in
/// `ui/AppViewModel.kt`.
///
/// Pure and separate from the widget because the modifier rules are the error-prone part: Ctrl only
/// applies to the *first* code point, Alt is an ESC prefix rather than a bit, and text that Ctrl has
/// no encoding for must survive intact rather than being masked into a different byte.
Uint8List encodeTypedText(
  String text, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  if (text.isEmpty) return Uint8List(0);

  // Shift upper-cases a single character only. Applying it to a longer run would rewrite a paste.
  var t = shift && text.runes.length == 1 ? text.toUpperCase() : text;

  if (!ctrl && !alt) return Uint8List.fromList(utf8.encode(t));

  final out = <int>[];
  if (alt) out.add(0x1B);

  final first = t.runes.first;
  final control = ctrl ? TerminalKeyEncoder.controlByte(first) : null;
  if (control != null) {
    out.add(control);
    final rest = String.fromCharCodes(t.runes.skip(1));
    if (rest.isNotEmpty) out.addAll(utf8.encode(rest));
  } else {
    // Ctrl has no portable byte for non-ASCII text. Preserve the whole scalar rather than splitting
    // it or emitting an arbitrary mask — a mangled code point is worse than an ignored modifier.
    out.addAll(utf8.encode(t));
  }
  return Uint8List.fromList(out);
}

/// Encodes a paste as one contiguous write.
///
/// Newlines normalise to CR, matching what Enter sends, so each pasted line is submitted the way the
/// shell expects. Sticky modifiers are deliberately ignored: a Ctrl held for one keystroke must not
/// silently rewrite the first byte of a hundred-line paste.
Uint8List encodePastedText(String text) =>
    Uint8List.fromList(utf8.encode(text.replaceAll('\r\n', '\r').replaceAll('\n', '\r')));

/// Kotlin's `String.toByteArray()` defaults to UTF-8; every sequence here is pure ASCII, for which
/// the two encodings are identical.
Uint8List _ascii(String s) => Uint8List.fromList(utf8.encode(s));
