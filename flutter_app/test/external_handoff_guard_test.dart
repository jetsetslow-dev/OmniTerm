import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Defect 74. Handing work to another app fails in two ways, and only one of them is a return
/// value: `launchUrl` answers `false` when a handler declines, and **throws** when there is no
/// handler at all. `SharePlus.share` only throws.
///
/// `_openUrl` in `about_screen.dart` already wrapped its call in a try/catch, so the throwing case
/// was known about. `_reportCrash` did not — so on a device with no browser its fallback (copy the
/// crash report to the clipboard) never ran, and the button did nothing at all: no browser, no copy,
/// no message. `_shareCrash` had no guard either, where Kotlin reports "Couldn't share the report"
/// (`MainActivity.kt:337`).
///
/// **This is a source scan, and that is a deliberate second choice.** Driving it through the UI
/// needs the launch to fail on demand, and `url_launcher_android` routes through pigeon channels
/// rather than the plain `MethodChannel` a test can stub by name — the stub is never consulted, the
/// launch "succeeds", and the test passes for the wrong reason. A scan cannot prove the fallback
/// *behaves*; it does prove no call site is left unguarded, which is the defect that happened.
void main() {
  /// Calls that hand off to another app and can throw when nothing is installed to receive them.
  const handoffs = ['launchUrl(', 'SharePlus.instance.share('];

  test('every hand-off to another app is guarded against there being no app', () {
    final unguarded = <String>[];

    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();

      for (var i = 0; i < lines.length; i++) {
        if (!handoffs.any(lines[i].contains)) continue;
        // A `try {` within the preceding 15 lines. Crude, but it checks for the presence of a guard
        // rather than reasoning about scope, and a false pass would need a `try` that is close by
        // and does not enclose the call.
        final window = lines.sublist((i - 15).clamp(0, i), i);
        if (window.any((line) => line.trimLeft().startsWith('try {'))) continue;
        unguarded.add('${file.path}:${i + 1}  ${lines[i].trim()}');
      }
    }

    expect(
      unguarded,
      isEmpty,
      reason:
          'These calls throw when no app can handle them, taking their own fallback down with '
          'them:\n  ${unguarded.join('\n  ')}',
    );
  });
}
