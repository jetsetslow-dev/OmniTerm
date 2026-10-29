import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/remote_parsers.dart';

/// The destination conflict scan, ported from `compareForConflicts` in `data/RemoteParsers.kt`.
///
/// **These run the generated script in a real `/bin/sh`.** A shell command built by string
/// concatenation is exactly the kind of code that looks right and is wrong: one over-escaped `$`
/// makes the script print the literal text `$OT_V` instead of a verdict, and no amount of reading
/// the Dart catches it. The fixtures are created here in a temp directory, so nothing depends on
/// what this machine happens to have lying around.
void main() {
  late Directory root;
  late Directory source;
  late Directory dest;

  setUp(() {
    root = Directory.systemTemp.createTempSync('omniterm-conflict-scan');
    source = Directory('${root.path}/src')..createSync();
    dest = Directory('${root.path}/dst')..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// Runs the scan and returns the parsed conflicts, failing if the sentinel is missing.
  List<TransferConflict> scan(List<String> sources) {
    final script = compareForConflicts(dest.path, sources);
    final run = Process.runSync('/bin/sh', ['-c', script]);
    expect(run.exitCode, 0, reason: 'scan script failed: ${run.stderr}');

    final output = run.stdout as String;
    expect(
      output.contains(conflictScanOk),
      isTrue,
      reason: 'a truncated scan must never be read as "no conflicts"',
    );
    final body = output.split('\n').where((line) => line.trim() != conflictScanOk).join('\n');
    return parseTransferConflicts(body, sources);
  }

  File writeFile(Directory dir, String name, String content) =>
      File('${dir.path}/$name')..writeAsStringSync(content);

  test('an empty source list produces no script at all', () {
    expect(compareForConflicts(dest.path, const []), '');
  });

  test('a name that does not exist at the destination is not a conflict', () {
    writeFile(source, 'only-here.txt', 'x');
    expect(scan(['${source.path}/only-here.txt']), isEmpty);
  });

  test('same size and same bytes is IDENTICAL, and defaults to overwrite', () {
    writeFile(source, 'a.txt', 'hello');
    writeFile(dest, 'a.txt', 'hello');

    final conflict = scan(['${source.path}/a.txt']).single;
    expect(conflict.name, 'a.txt');
    expect(conflict.verdict, ConflictVerdict.identical);
    expect(
      conflict.action,
      ConflictAction.overwrite,
      reason: 'overwriting proven-identical bytes destroys nothing',
    );
  });

  test('same size but different bytes is DIFFERENT, not IDENTICAL', () {
    // The whole reason the scan hashes: size and mtime alone would call these a match.
    writeFile(source, 'a.txt', 'hello');
    writeFile(dest, 'a.txt', 'HELLO');

    final conflict = scan(['${source.path}/a.txt']).single;
    expect(conflict.verdict, ConflictVerdict.different);
    expect(conflict.action, ConflictAction.keepBoth);
  });

  test('differing sizes are decisive without hashing', () {
    writeFile(source, 'a.txt', 'short');
    writeFile(dest, 'a.txt', 'considerably longer contents');

    final conflict = scan(['${source.path}/a.txt']).single;
    expect(conflict.verdict, ConflictVerdict.different);
    expect(conflict.sourceSize, 5);
    expect(conflict.destSize, 28);
  });

  test('a directory reports DIR because it merges rather than replaces', () {
    Directory('${source.path}/shared').createSync();
    Directory('${dest.path}/shared').createSync();

    final conflict = scan(['${source.path}/shared']).single;
    expect(conflict.verdict, ConflictVerdict.directory);
    expect(conflict.action, ConflictAction.keepBoth);
  });

  test('several sources are reported against their own names', () {
    writeFile(source, 'same.txt', 'x');
    writeFile(dest, 'same.txt', 'x');
    writeFile(source, 'diff.txt', 'aaa');
    writeFile(dest, 'diff.txt', 'bbbb');
    writeFile(source, 'absent.txt', 'x');

    final conflicts = scan([
      '${source.path}/same.txt',
      '${source.path}/diff.txt',
      '${source.path}/absent.txt',
    ]);

    expect(conflicts, hasLength(2), reason: 'absent.txt does not clash');
    expect(conflicts.map((c) => c.name), ['same.txt', 'diff.txt']);
    expect(conflicts[0].verdict, ConflictVerdict.identical);
    expect(conflicts[1].verdict, ConflictVerdict.different);
  });

  test('a filename containing a tab cannot corrupt the line protocol', () {
    // Why the wire format keys on the source index rather than the basename: a tab in a name would
    // otherwise split into extra fields and silently shift every verdict along by one.
    const awkward = 'we\tird.txt';
    writeFile(source, awkward, 'x');
    writeFile(dest, awkward, 'x');

    final conflict = scan(['${source.path}/$awkward']).single;
    expect(conflict.name, awkward);
    expect(conflict.verdict, ConflictVerdict.identical);
  });

  test("a name with a quote and a space survives shell quoting", () {
    const awkward = "it's a file.txt";
    writeFile(source, awkward, 'x');
    writeFile(dest, awkward, 'y');

    final conflict = scan(['${source.path}/$awkward']).single;
    expect(conflict.name, awkward);
    expect(conflict.verdict, ConflictVerdict.different);
  });

  test('the destination path is quoted, so a space in it still scans', () {
    final spaced = Directory('${root.path}/dest with space')..createSync();
    writeFile(source, 'a.txt', 'x');
    File('${spaced.path}/a.txt').writeAsStringSync('x');

    final script = compareForConflicts(spaced.path, ['${source.path}/a.txt']);
    final run = Process.runSync('/bin/sh', ['-c', script]);
    expect(run.exitCode, 0);
    expect(run.stdout as String, contains('IDENTICAL'));
  });
}
