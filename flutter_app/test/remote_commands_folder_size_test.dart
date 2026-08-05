import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';

void main() {
  group('folderSizeCommand', () {
    test('the path is quoted, not interpolated', () {
      // A remote path is not this app's text: it comes from a listing on someone else's machine.
      // A directory called `; rm -rf ~` is legal on every Unix filesystem.
      final command = folderSizeCommand('/srv/; rm -rf ~');

      expect(command, contains(r"'/srv/; rm -rf ~'"));
      expect(command, isNot(contains('du -shx -- /srv/; rm')));
    });

    test("a single quote in the name cannot close the quoting", () {
      // The one character that could escape a single-quoted string, and the reason `shellQuote`
      // exists rather than a pair of quotes around the value.
      final command = folderSizeCommand("/srv/it's");

      expect(command, contains(r"'/srv/it'\''s'"));
    });

    test('it stays on one filesystem', () {
      // Measuring `/` on a host with network mounts would otherwise wander into them and hang.
      // Combined with -s and -h, hence `-shx` rather than a separate flag.
      expect(folderSizeCommand('/'), contains('du -shx'));
    });

    test('errors are kept rather than discarded', () {
      // `du` reports a *partial* total when it cannot read part of the tree, so the warning is what
      // tells the caller the number is a floor rather than the answer.
      expect(folderSizeCommand('/srv'), contains('2>&1'));
    });
  });

  group('parseFolderSize', () {
    test('the ordinary answer', () {
      // Real output from the lab: `du -shx -- '/config'` prints `120K\t/config`.
      expect(parseFolderSize('120K\t/config\n')!.size, '120K');
      expect(parseFolderSize('120K\t/config\n')!.complete, isTrue);
      expect(parseFolderSize('1.2G\t/srv/media\n')!.size, '1.2G');
    });

    test('a bare byte count with no suffix', () {
      // `du -s` on a host whose du ignores `-h`.
      expect(parseFolderSize('284\t/srv\n')!.size, '284');
    });

    test('a partial total is returned *and* flagged', () {
      // Exactly what a real host produces for a directory the login cannot fully read — a warning,
      // then a partial total, then a non-zero exit. Reporting 4.0K alone would be a confident wrong
      // answer about something far larger; reporting nothing would discard a real lower bound.
      const output = "du: cannot read directory '/root': Permission denied\n4.0K\t/root\n";
      final size = parseFolderSize(output)!;

      expect(size.size, '4.0K');
      expect(size.complete, isFalse);
    });

    test('a path that does not exist yields no number at all', () {
      // Also observed: `du: cannot access '/nope': No such file or directory`, with no total line.
      expect(parseFolderSize("du: cannot access '/nope': No such file or directory\n"), isNull);
    });

    test('a host with no du is reported as unmeasurable, not as zero', () {
      // Zero would read as "this folder is empty", which is a different and wrong statement.
      expect(parseFolderSize('sh: du: not found\n'), isNull);
    });

    test('output carrying nothing size-shaped is null', () {
      expect(parseFolderSize(''), isNull);
      expect(parseFolderSize('something went wrong\n'), isNull);
    });
  });
}
