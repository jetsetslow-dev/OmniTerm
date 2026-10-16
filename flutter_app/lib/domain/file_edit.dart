/// Deciding whether a remote file can be edited, and whether a save actually happened.
///
/// Ported from the editor half of `sftpSaveText` in `ui/AppViewModel.kt`. The rule it encodes is
/// the reason that function exists: **a write that returned without throwing is not proof the file
/// was written.** SFTP will happily report success against a full disk, a quota, or a path that
/// silently resolved somewhere else. So the size is read back and compared, and only a match is
/// reported as saved.
///
/// Kept out of the widget so the decision can be tested without a server (convention 3).
library;

import 'dart:typed_data';

/// How much of a file the editor will pull down.
///
/// Not a performance limit — the transport caps its own read — but an honesty one: past this size a
/// mobile editor is not a good way to change a file, and pretending otherwise wastes the user's
/// time and their data allowance.
const maxEditableBytes = 512 * 1024;

/// Whether [size] bytes is worth opening in the editor.
bool isEditableSize(int size) => size >= 0 && size <= maxEditableBytes;

/// Whether [bytes] looks like text rather than a binary.
///
/// A NUL byte is the giveaway: no text encoding this app will meet uses one, and every common
/// binary format has them early. Deliberately a *warning* signal for the caller rather than a
/// refusal (§17) — an operator who knows what they are doing may still want to look.
bool looksBinary(Uint8List bytes) {
  final limit = bytes.length < 8000 ? bytes.length : 8000;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// Why editing [text] as text would damage it, or null when it is safe.
///
/// The editor receives an already-decoded string: the SFTP client reads with
/// `utf8.decode(..., allowMalformed: true)`, so bytes that are not valid UTF-8 have **already become
/// U+FFFD** by the time anything here sees them. That is the dangerous case, and it is invisible on
/// screen — the replacement character renders as an ordinary glyph, and saving writes those three
/// bytes back over whatever was there, corrupting the file for good.
///
/// A warning rather than a refusal (§17), matching [looksBinary]: an operator who knows what they
/// are doing may still want to look at the file.
String? binaryEditWarning(String text) {
  if (text.contains('\u0000')) {
    return 'This file contains NUL bytes, so it is binary rather than text. '
        'Saving it from the editor will corrupt it.';
  }
  if (text.contains('\uFFFD')) {
    return 'Parts of this file are not valid UTF-8 text and were replaced with "�" when it '
        'was read. Saving will write those replacements over the original bytes.';
  }
  return null;
}

/// What a save attempt amounted to.
enum FileSaveOutcome {
  /// The remote reported exactly the bytes that were sent.
  confirmed,

  /// The write did not throw, but the size could not be read back to prove it landed.
  unconfirmed,

  /// The remote reported a different size. The edits are still in the editor.
  mismatch,

  /// The write itself failed.
  failed,
}

/// The result of a save, with the message the user should see.
class FileSaveResult {
  const FileSaveResult(this.outcome, this.message);

  final FileSaveOutcome outcome;
  final String message;

  /// Whether the editor may close. A save that could not be confirmed must not throw the user's
  /// work away — that is the difference between a failed save and a lost one.
  bool get canClose =>
      outcome == FileSaveOutcome.confirmed || outcome == FileSaveOutcome.unconfirmed;

  bool get isError => outcome == FileSaveOutcome.mismatch || outcome == FileSaveOutcome.failed;
}

/// Judges a completed write.
///
/// [expected] is the byte length that was sent; [reported] is what the remote said afterwards, or a
/// negative number when it could not be read back.
FileSaveResult judgeSave({required String name, required int expected, required int reported}) {
  if (reported < 0) {
    // The write did not throw, so the bytes most likely landed — but say plainly that nothing
    // checked, rather than claiming a confirmation that was never obtained.
    return FileSaveResult(
      FileSaveOutcome.unconfirmed,
      'Saved "$name", but the size could not be read back to confirm it.',
    );
  }
  if (reported == expected) {
    return FileSaveResult(
      FileSaveOutcome.confirmed,
      'Saved "$name" — $reported bytes confirmed on the server.',
    );
  }
  return FileSaveResult(
    FileSaveOutcome.mismatch,
    'Save not confirmed: the server reports $reported bytes, expected $expected. '
    'Your edits are still here — try saving again.',
  );
}

/// The message for a write that threw.
FileSaveResult saveFailed(Object error) =>
    FileSaveResult(FileSaveOutcome.failed, 'Save failed: $error');
