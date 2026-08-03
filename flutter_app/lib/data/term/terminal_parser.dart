/// The VT/xterm escape-sequence state machine, extracted from `TerminalEmulator.kt`
/// (`processCodePoint` / `ground` / `esc` / `csi` / `osc` / `discardString`, Kotlin lines 438–514).
///
/// The Kotlin had the parser call screen operations directly. Here it is a **pure lexer**: it owns
/// only the parse state and reports semantic events to a [TerminalSink]. That is the shape vte and
/// vtparse use, and it is what makes the sequence handling testable on its own — a parser that
/// mutates a screen can only be tested through the screen.
///
/// Behaviour is unchanged, including the defensive parts that matter most:
///  - unknown sequences are **ignored**, never rendered as text (`docs/TERMINAL_COMPATIBILITY.md`);
///  - a control sequence longer than [maxControlSequenceChars] is abandoned rather than buffered,
///    so a remote cannot grow memory without bound by never sending a final byte.
library;

/// Receives the semantic events the parser recognises.
abstract interface class TerminalSink {
  /// A printable code point in the ground state.
  void print(int codePoint);

  /// A C0 control that reached the ground state (BS, HT, LF, VT, FF, CR).
  void execute(int control);

  /// A complete CSI sequence. [params] is the raw parameter/intermediate text with any leading `?`
  /// already stripped into [private]; [finalByte] is the dispatch character.
  void csiDispatch(String params, {required bool private, required String finalByte});

  /// A complete two-character ESC sequence (`M`, `D`, `E`, `7`, `8`).
  void escDispatch(String finalByte);

  /// `ESC c` — full reset.
  void fullReset();
}

enum _ParserState { ground, esc, csi, osc, discardString, charset }

class TerminalParser {
  TerminalParser(this._sink);

  /// Cap on a single control sequence. A remote that never sends a final byte must not be able to
  /// grow the parameter buffer indefinitely.
  static const maxControlSequenceChars = 1024;

  final TerminalSink _sink;

  _ParserState _state = _ParserState.ground;
  final StringBuffer _csiParams = StringBuffer();
  bool _oscEscSeen = false;
  bool _discardEscSeen = false;

  /// True when no sequence is part-way through. Exposed for tests and for reset handling.
  bool get isGround => _state == _ParserState.ground;

  void reset() {
    _state = _ParserState.ground;
    _csiParams.clear();
    _oscEscSeen = false;
    _discardEscSeen = false;
  }

  void processCodePoint(int codePoint) {
    // Astral code points cannot appear inside a control sequence, and the Kotlin could not even
    // represent them as a Char — so they print in the ground state and are dropped anywhere else.
    if (codePoint > 0xFFFF) {
      if (_state == _ParserState.ground) _sink.print(codePoint);
      return;
    }

    switch (_state) {
      case _ParserState.ground:
        _ground(codePoint);
      case _ParserState.esc:
        _esc(codePoint);
      case _ParserState.csi:
        _csi(codePoint);
      case _ParserState.osc:
        _osc(codePoint);
      case _ParserState.discardString:
        _discardString(codePoint);
      case _ParserState.charset:
        // Consume the single charset designator that follows ESC ( ) * +.
        _state = _ParserState.ground;
    }
  }

  void _ground(int c) {
    switch (c) {
      case 0x07: // BEL — no audible bell on a phone
        break;
      case 0x08: // BS
      case 0x09: // HT
      case 0x0A: // LF
      case 0x0B: // VT
      case 0x0C: // FF
      case 0x0D: // CR
        _sink.execute(c);
      case 0x1B: // ESC
        _state = _ParserState.esc;
      case 0x7F: // DEL — ignored
        break;
      default:
        // Every other C0 control is ignored rather than printed as a glyph.
        if (c >= 0x20) _sink.print(c);
    }
  }

  void _esc(int c) {
    switch (String.fromCharCode(c)) {
      case '[':
        _csiParams.clear();
        _state = _ParserState.csi;
      case ']':
        _oscEscSeen = false;
        _state = _ParserState.osc;
      case 'P': // DCS
      case '_': // APC
      case '^': // PM
        _discardEscSeen = false;
        _state = _ParserState.discardString;
      case '(':
      case ')':
      case '*':
      case '+':
        _state = _ParserState.charset;
      case '=':
      case '>': // keypad modes — ignored
        _state = _ParserState.ground;
      case 'M': // reverse index
      case 'D': // index
      case 'E': // next line
      case '7': // save cursor
      case '8': // restore cursor
        _sink.escDispatch(String.fromCharCode(c));
        _state = _ParserState.ground;
      case 'c':
        _sink.fullReset();
        _state = _ParserState.ground;
      default:
        _state = _ParserState.ground;
    }
  }

  /// OSC strings are terminated by BEL or ST (`ESC \`). The payload is ignored — titles,
  /// hyperlinks, clipboard writes and notifications are all deliberately not acted on.
  void _osc(int c) {
    if (c == 0x07) {
      _state = _ParserState.ground;
      return;
    }
    if (_oscEscSeen && c == 0x5C) {
      _state = _ParserState.ground;
      return;
    }
    _oscEscSeen = c == 0x1B;
  }

  void _csi(int c) {
    // Parameter bytes (0x30–0x3F) plus the two intermediates this subset accepts.
    if ((c >= 0x30 && c <= 0x3F) || c == 0x20 || c == 0x21) {
      if (_csiParams.length < maxControlSequenceChars) {
        _csiParams.write(String.fromCharCode(c));
      } else {
        _csiParams.clear();
        _state = _ParserState.ground;
      }
      return;
    }
    if (c >= 0x40 && c <= 0x7E) {
      final raw = _csiParams.toString();
      final private = raw.startsWith('?');
      _sink.csiDispatch(
        private ? raw.substring(1) : raw,
        private: private,
        finalByte: String.fromCharCode(c),
      );
      _state = _ParserState.ground;
      return;
    }
    _state = _ParserState.ground; // anything else aborts the sequence
  }

  /// DCS/APC/PM payloads are swallowed whole, terminated by BEL or ST.
  void _discardString(int c) {
    if (c == 0x07) {
      _discardEscSeen = false;
      _state = _ParserState.ground;
      return;
    }
    if (_discardEscSeen && c == 0x5C) {
      _discardEscSeen = false;
      _state = _ParserState.ground;
      return;
    }
    _discardEscSeen = c == 0x1B;
  }
}

/// Parses a CSI parameter string into its numeric parameters.
///
/// An omitted parameter is null rather than 0, because the two mean different things: `CSI ;5H`
/// leaves the row defaulted while setting the column. Callers use [csiParam] / [csiParamOrOne] to
/// apply the right default per sequence.
List<int?> parseCsiParams(String body) =>
    body.split(';').map((p) => int.tryParse(p)).toList();

/// Parameter [index] with a caller-supplied default for absent/unparseable values.
int csiParam(List<int?> params, int index, {int fallback = 0}) =>
    (index >= 0 && index < params.length ? params[index] : null) ?? fallback;

/// Parameter [index] where 0 and absent both mean 1 — the convention for movement counts, so
/// `CSI A` and `CSI 0A` both move one row.
int csiParamOrOne(List<int?> params, int index) {
  final value = (index >= 0 && index < params.length ? params[index] : null) ?? 0;
  return value == 0 ? 1 : value;
}
