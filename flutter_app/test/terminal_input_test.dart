import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/terminal_key_encoder.dart';
import 'package:omniterm/domain/terminal_soft_input.dart';

void main() {
  String decode(List<int> bytes) => utf8.decode(bytes);

  group('typed text under sticky modifiers', () {
    test('plain text passes through as UTF-8', () {
      expect(decode(encodeTypedText('ls -la')), 'ls -la');
      expect(decode(encodeTypedText('ünïcödé')), 'ünïcödé');
    });

    test('Ctrl produces the control byte', () {
      expect(encodeTypedText('c', ctrl: true), [0x03]);
      expect(encodeTypedText('C', ctrl: true), [0x03], reason: 'case-insensitive');
      expect(encodeTypedText('d', ctrl: true), [0x04]);
    });

    test('Ctrl applies to the first code point only, and the rest survives', () {
      // A soft keyboard can commit several characters at once; a stuck Ctrl must not eat them.
      expect(encodeTypedText('cat', ctrl: true), [0x03, 0x61, 0x74]);
    });

    test('Alt is an ESC prefix, not a bit', () {
      expect(encodeTypedText('b', alt: true), [0x1B, 0x62]);
      expect(encodeTypedText('c', alt: true, ctrl: true), [0x1B, 0x03]);
    });

    test('text Ctrl cannot encode survives intact rather than being masked', () {
      // Emitting an arbitrary byte here would send a different character than the user typed, which
      // in a shell is a different command.
      expect(decode(encodeTypedText('é', ctrl: true)), 'é');
    });

    test('Shift upper-cases a single character only', () {
      expect(decode(encodeTypedText('a', shift: true)), 'A');
      // Applying it to a run would rewrite a whole pasted line.
      expect(decode(encodeTypedText('abc', shift: true)), 'abc');
    });

    test('empty input produces no bytes', () {
      expect(encodeTypedText(''), isEmpty);
    });
  });

  group('paste', () {
    test('newlines normalise to CR so each line is submitted', () {
      // LF alone only moves the cursor: the shell would sit there with the command unsubmitted.
      expect(decode(encodePastedText('a\nb')), 'a\rb');
      expect(decode(encodePastedText('a\r\nb')), 'a\rb');
      expect(decode(encodePastedText('a\rb')), 'a\rb');
    });

    test('the whole block is kept', () {
      final lines = List.generate(50, (i) => 'line$i').join('\n');
      expect(decode(encodePastedText(lines)).split('\r'), hasLength(50));
    });

    group('bracketed paste (DECSET 2004)', () {
      // The emulator tracked the mode and nothing read it, so every paste reached the remote as
      // plain typing — the one thing bracketed paste exists to prevent. Kotlin builds the payload
      // at `ui/AppViewModel.kt:696`.
      const begin = '[200~';
      const end = '[201~';

      test('is off unless the remote asked for it', () {
        expect(decode(encodePastedText('ls -la')), 'ls -la');
        expect(bracketedPastePayload('ls -la', false), 'ls -la');
      });

      test('wraps the body in the standard markers', () {
        expect(bracketedPastePayload('ls -la', true), '${begin}ls -la$end');
      });

      test('interior newlines stay inside the brackets, literal as the mode intends', () {
        // This is the protection: a multi-line paste arrives as text, not as three commands the
        // shell runs before the user can read them.
        expect(bracketedPastePayload('one\rtwo\rthree', true), '${begin}one\rtwo\rthree$end');
      });

      test('a trailing Enter is sent after the closing marker, so it still submits', () {
        // readline treats everything between the markers as literal — a trailing CR included — so
        // wrapping it would leave the command echoed at the prompt and never run.
        expect(bracketedPastePayload('ls -la\r', true), '${begin}ls -la$end\r');
        expect(bracketedPastePayload('ls -la\r\r', true), '${begin}ls -la$end\r\r');
      });

      test('a paste that is only newlines is all Enter presses', () {
        expect(bracketedPastePayload('\r\r', true), '$begin$end\r\r');
      });

      test('the encoder wraps once the mode is on', () {
        expect(decode(encodePastedText('a\nb\n', bracketed: true)), '${begin}a\rb$end\r');
      });
    });
  });

  group('smart swipe line edit', () {
    test('autocorrect replaces the changed tail', () {
      expect(terminalLineEdit('git statsu', 'git status'), (backspaces: 2, insert: 'us'));
    });

    test('emoji count as one remote backspace', () {
      expect(terminalLineEdit('echo 😀', 'echo 😁'), (backspaces: 1, insert: '😁'));
      expect(insertedTerminalRuneDelta('a😀z', 'a😁z'), 1);
    });

    test('an unchanged affix is excluded from the paste delta', () {
      expect(insertedTerminalRuneDelta('prefix old suffix', 'prefix new suffix'), 3);
    });
  });

  group('software keyboard commits', () {
    test('a lone newline is the Enter key, not a newline character', () {
      // The distinction the Kotlin comment calls out: an IME commits "\n", a PTY expects CR.
      expect(interpretSoftInput('\n'), const SoftInputEnter());
      expect(interpretSoftInput('\r'), const SoftInputEnter());
      expect(interpretSoftInput('\r\n'), const SoftInputEnter());
    });

    test('ordinary typing is typed', () {
      expect(interpretSoftInput('ls'), const SoftInputType('ls'));
    });

    test('a multi-line block keeps every line', () {
      // An earlier Kotlin version submitted only the first line and dropped the remainder.
      const block = 'cd /srv\nls -la\n';
      expect(interpretSoftInput(block), const SoftInputPaste(block));
    });

    test('a long single-line commit is treated as a paste', () {
      final long = 'x' * (softInputPasteThreshold + 1);
      expect(interpretSoftInput(long), SoftInputPaste(long));
    });

    test('a commit exactly at the threshold is still typing', () {
      final atLimit = 'x' * softInputPasteThreshold;
      expect(interpretSoftInput(atLimit), SoftInputType(atLimit));
    });

    test('an empty commit does nothing', () {
      expect(interpretSoftInput(''), isNull);
    });
  });
}
