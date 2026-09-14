/// How a software-keyboard commit should reach the remote.
///
/// Ported from the `BasicTextField` commit handler in `ui/ShellScreen.kt`, kept as a pure decision
/// because it is the one place a soft keyboard's idea of text and a PTY's idea of keystrokes have to
/// be reconciled, and getting it wrong is invisible until someone's command runs a line early.
library;

sealed class SoftInputAction {
  const SoftInputAction();
}

/// Ordinary typing: send the characters as-is.
class SoftInputType extends SoftInputAction {
  const SoftInputType(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is SoftInputType && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'SoftInputType(${jsonish(text)})';
}

/// The Enter key, which a PTY expects as CR — not as the newline the IME actually committed.
class SoftInputEnter extends SoftInputAction {
  const SoftInputEnter();

  @override
  bool operator ==(Object other) => other is SoftInputEnter;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'SoftInputEnter()';
}

/// A multi-line or large block: one contiguous write with newlines normalised.
class SoftInputPaste extends SoftInputAction {
  const SoftInputPaste(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is SoftInputPaste && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'SoftInputPaste(${text.length} chars)';
}

/// A commit long enough that it is a paste rather than typing, regardless of its content.
///
/// Sending a thousand characters through the typing path is not wrong so much as slow and
/// interleavable; routing it as one write keeps the bytes contiguous.
const softInputPasteThreshold = 100;

/// One editor-style edit to mirror into a remote shell line.
typedef TerminalLineEdit = ({int backspaces, String insert});

/// Converts an IME/autocorrect replacement into terminal DEL bytes plus a replacement tail.
///
/// Dart strings are UTF-16, while a terminal backspace removes one Unicode scalar. Comparing rune
/// lists avoids sending two DELs for one emoji.
TerminalLineEdit terminalLineEdit(String oldText, String newText) {
  final oldRunes = oldText.runes.toList(growable: false);
  final newRunes = newText.runes.toList(growable: false);
  var prefix = 0;
  final commonLength = oldRunes.length < newRunes.length ? oldRunes.length : newRunes.length;
  while (prefix < commonLength && oldRunes[prefix] == newRunes[prefix]) {
    prefix++;
  }
  return (
    backspaces: oldRunes.length - prefix,
    insert: String.fromCharCodes(newRunes.skip(prefix)),
  );
}

/// Size of the changed middle of [newText], used to distinguish paste from incremental swipe edits.
int insertedTerminalRuneDelta(String oldText, String newText) {
  final oldRunes = oldText.runes.toList(growable: false);
  final newRunes = newText.runes.toList(growable: false);
  final max = oldRunes.length < newRunes.length ? oldRunes.length : newRunes.length;
  var prefix = 0;
  while (prefix < max && oldRunes[prefix] == newRunes[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < max - prefix &&
      oldRunes[oldRunes.length - 1 - suffix] == newRunes[newRunes.length - 1 - suffix]) {
    suffix++;
  }
  return (newRunes.length - prefix - suffix).clamp(0, newRunes.length);
}

/// True only for a commit that is exactly one line break.
///
/// A software keyboard's Enter arrives as a newline character, but an interactive PTY wants the
/// terminal Enter key (CR). Sending the raw LF only moves the cursor and leaves the command pending
/// until the user presses Enter a second time.
bool isSingleTerminalEnter(String text) => text == '\n' || text == '\r' || text == '\r\n';

/// Decide what a software-keyboard commit of [text] should send.
SoftInputAction? interpretSoftInput(String text) {
  if (text.isEmpty) return null;
  if (isSingleTerminalEnter(text)) return const SoftInputEnter();
  // Anything else carrying a line break is a block the user pasted or dictated. Submitting only its
  // first line — which an earlier version of the Kotlin did — silently discarded the remainder.
  if (text.contains('\n') || text.contains('\r')) return SoftInputPaste(text);
  if (text.runes.length > softInputPasteThreshold) return SoftInputPaste(text);
  return SoftInputType(text);
}

/// Quote a short string for a debug description without pulling in `dart:convert`.
String jsonish(String s) =>
    '"${s.replaceAll('\\', r'\\').replaceAll('\n', r'\n').replaceAll('\r', r'\r')}"';
