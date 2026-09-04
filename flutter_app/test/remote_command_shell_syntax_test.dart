import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';

/// Every generated remote command must be valid POSIX `sh`.
///
/// These strings are built by concatenation, so an edit can leave a shell construct unbalanced — an
/// `else`/`fi` bolted onto what was really an `&&` chain, an unclosed quote, a missing `done`. Dart
/// cannot see any of that: it is a perfectly valid Dart string that happens to be broken shell.
///
/// The failure mode is severe and silent: `sh` aborts the whole script at the syntax error, so one
/// bad section takes out every section after it. The metrics probe returns nothing, the host shows
/// no memory or disk at all, and alerts depending on those values never fire. Exactly that bug was
/// introduced on the Kotlin side and only surfaced in an emulator run; `sh -n` catches it instantly.
///
/// Mirrors `RemoteCommandShellSyntaxTest` in the Kotlin app.
void main() {
  String? shellPath() {
    for (final candidate in ['/bin/sh', '/usr/bin/sh', '/bin/dash']) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  final sh = shellPath();

  final commands = <String, String>{
    'metricsLinux': metricsLinux,
    'dockerPsCommand': dockerPsCommand,
    'dockerRuntimesCommand': dockerRuntimesCommand,
    'dockerRestartsCommand': dockerRestartsCommand,
    'dockerImagesCommand': dockerImagesCommand,
    'dockerVolumesCommand': dockerVolumesCommand,
    'dockerNetworksCommand': dockerNetworksCommand,
    'servicesCommand': servicesCommand,
  };

  test('every generated remote command parses as POSIX sh', () {
    if (sh == null) return; // no shell on this runner; the Kotlin twin still covers it
    final dir = Directory.systemTemp.createTempSync('omniterm_shell_syntax');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final entry in commands.entries) {
      // Written to a file rather than piped: `sh -n` with no argument reads the *parent's* stdin,
      // which under `flutter test` is not the script and makes the check pass without parsing
      // anything at all.
      final file = File('${dir.path}/${entry.key}.sh')..writeAsStringSync(entry.value);
      final result = Process.runSync(sh, ['-n', file.path]);
      expect(
        result.exitCode,
        0,
        reason:
            '${entry.key} is not valid POSIX sh:\n${result.stderr}\n\n--- script ---\n${entry.value}',
      );
    }
  });

  test('every command that calls ot also defines it', () {
    final usesOt = RegExp(r'\bot \d+ ');
    for (final entry in commands.entries) {
      if (usesOt.hasMatch(entry.value)) {
        expect(
          entry.value.contains('ot(){'),
          isTrue,
          reason: '${entry.key} calls `ot` but never defines it (missing otHelper)',
        );
      }
    }
  });
}
