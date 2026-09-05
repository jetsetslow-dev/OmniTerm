import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every icon-only control must carry an accessible name.
///
/// An `IconButton` with no `tooltip` and no `semanticLabel` on its icon is announced by TalkBack as
/// "button" and nothing else. On this app that meant thirty controls — every dismiss, every close,
/// the find-bar arrows, the numeric steppers — were unidentifiable to a screen-reader user, while
/// the Kotlin labels them with `contentDescription` (179 of them, `ui/*.kt`).
///
/// This is a source scan rather than a widget test on purpose. The defect is not that one screen is
/// wrong; it is that nothing stopped the next one being wrong, and a per-screen test only covers the
/// screens someone remembered to write a test for.
void main() {
  test('no icon-only control ships without an accessible name', () {
    final offenders = <String>[];

    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();

      for (final match in RegExp(r'IconButton\(').allMatches(source)) {
        // Walk to the matching close paren so nested widgets in the body are included.
        var i = match.end;
        var depth = 1;
        while (i < source.length && depth > 0) {
          if (source[i] == '(') {
            depth++;
          } else if (source[i] == ')') {
            depth--;
          }
          i++;
        }
        final body = source.substring(match.end, i);
        if (body.contains('tooltip:') || body.contains('semanticLabel')) continue;

        final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        final key = RegExp(r"ValueKey\('([^']+)'\)").firstMatch(body)?.group(1);
        offenders.add('${file.path}:$line${key == null ? '' : "  ($key)"}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These icon buttons announce as "button" with no name. Give each a `tooltip:` — it '
          'supplies the semantics and a long-press label at once:\n  ${offenders.join('\n  ')}',
    );
  });
}
