import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every dialog must be able to survive not fitting.
///
/// An `AlertDialog` clips its content rather than scrolling it. A `content:` that is a multi-child
/// `Column` with nothing scrollable inside therefore loses its bottom rows on a small phone in
/// landscape at 200% text — and the bottom of a dialog is where the error message and the buttons
/// live. Parity defect 113 lost the PIN dialog's own "the two entries do not match"; defect 114
/// found six more with the same shape.
///
/// A source scan rather than a widget test, for the reason `accessibility_labels_test.dart` gives:
/// the defect is not that one dialog is wrong, it is that nothing stopped the next one being wrong.
/// Measuring each dialog by hand needs a harness per screen and, worse, the *right geometry* — 113
/// passed at the emulator's 914x411 and only failed at 640x360, so a device sweep cannot see this
/// class at all.
///
/// A dialog satisfies this rule by either:
///   * declaring `scrollable: true`, so Material wraps the content itself, or
///   * holding its own `SingleChildScrollView`, `ListView`, `Expanded` or `Flexible`, which absorbs
///     the overflow. Wrapping *those* in `scrollable: true` is how nested-scroll bugs are made, so
///     they are deliberately allowed rather than "fixed".
void main() {
  test('no dialog can clip its own content', () {
    final offenders = <String>[];

    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();

      for (final match in RegExp(r'\bAlertDialog\(').allMatches(source)) {
        // Walk to the matching close paren so the whole dialog — including nested widgets — is
        // considered, and one dialog's body cannot leak into the next one's.
        var i = match.end;
        var depth = 1;
        while (i < source.length && depth > 0) {
          final char = source[i];
          if (char == '(') {
            depth++;
          } else if (char == ')') {
            depth--;
          }
          i++;
        }
        final body = source.substring(match.end, i);

        // Only a multi-child Column can lose rows. A dialog whose content is a single widget either
        // fits or is already someone else's problem to lay out.
        final content = RegExp(r'content:\s*(?:SizedBox\(|ConstrainedBox\()?[^,]*?Column\(');
        if (!content.hasMatch(body)) continue;

        final absorbs =
            body.contains('scrollable: true') ||
            body.contains('SingleChildScrollView') ||
            body.contains('ListView') ||
            body.contains('Expanded(') ||
            body.contains('Flexible(');
        if (absorbs) continue;

        final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${file.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These dialogs hold a multi-child Column with nothing to absorb overflow, so they clip '
          'their bottom rows on a small phone at 200% text. Add `scrollable: true`, or give the '
          'content its own scrollable:\n  ${offenders.join('\n  ')}',
    );
  });
}
