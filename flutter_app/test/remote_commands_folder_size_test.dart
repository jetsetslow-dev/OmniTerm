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

  group('remoteSearchCommand', () {
    test('a bare term is matched anywhere in the name', () {
      // What a person typing three letters into a search box means.
      expect(remoteSearchCommand('/config', 'beta'), contains("-iname '*beta*'"));
    });

    test('a term carrying a wildcard is taken at its word', () {
      expect(remoteSearchCommand('/config', '*.conf'), contains("-iname '*.conf'"));
      expect(remoteSearchCommand('/config', 'log?'), contains("-iname 'log?'"));
    });

    test('both the path and the term are quoted', () {
      // Neither is this app's text: the path comes from a listing on someone else's machine and
      // the term is typed by a user.
      final command = remoteSearchCommand('/srv/; rm -rf ~', r'$(id)');

      expect(command, contains(r"'/srv/; rm -rf ~'"));
      expect(command, contains(r"'*$(id)*'"));
      expect(command, isNot(contains('find /srv/; rm')));
    });

    test('one more than the limit is fetched', () {
      // That extra hit is how truncation is known rather than guessed at.
      expect(remoteSearchCommand('/', 'x', maxHits: 200), contains('head -n 201'));
    });

    test('an empty base searches the whole host rather than nothing', () {
      expect(remoteSearchCommand('', 'x'), contains("find '/'"));
    });

    test('the type tagging is POSIX sh, not GNU find', () {
      // `find -printf` does not exist on BSD, macOS or busybox — between them, a large part of what
      // people run at home.
      final command = remoteSearchCommand('/config', 'x');
      expect(command, isNot(contains('-printf')));
      expect(command, contains('while IFS= read -r p'));
    });
  });

  group('parseRemoteSearch', () {
    test('a tagged file hit, exactly as the lab produced it', () {
      final result = parseRemoteSearch(
        'f\t/config/searchprobe/nested/beta.conf\n',
        base: '/config',
      );

      expect(result.hits.single.path, '/config/searchprobe/nested/beta.conf');
      expect(result.hits.single.isDirectory, isFalse);
      expect(result.truncated, isFalse);
    });

    test('a directory hit is distinguished', () {
      final result = parseRemoteSearch('d\t/config/searchprobe\n', base: '/config');
      expect(result.hits.single.isDirectory, isTrue);
    });

    test('the folder being searched is not offered as a result', () {
      // Observed on a real host: `find /config/searchprobe -iname "*searchprobe*"` emits the base
      // directory itself, and offering the folder you are already in is noise.
      final result = parseRemoteSearch(
        'd\t/config/searchprobe\nf\t/config/searchprobe/alpha.conf\n',
        base: '/config/searchprobe',
      );

      expect(result.hits, hasLength(1));
      expect(result.hits.single.path, '/config/searchprobe/alpha.conf');
    });

    test('names with spaces and quotes survive', () {
      // Also from the lab: `it's a file.conf` came back intact.
      final result = parseRemoteSearch(
        "f\t/config/searchprobe/it's a file.conf\n",
        base: '/config',
      );

      expect(result.hits.single.path, "/config/searchprobe/it's a file.conf");
    });

    test('exactly the limit is not called truncated', () {
      // Crying wolf on a search that happened to return a full page would teach the user to ignore
      // the warning that matters.
      final output = List.generate(3, (i) => 'f\t/a/$i').join('\n');
      final result = parseRemoteSearch(output, base: '/a', maxHits: 3);

      expect(result.hits, hasLength(3));
      expect(result.truncated, isFalse);
    });

    test('one over the limit is truncated, and the extra is not shown', () {
      final output = List.generate(4, (i) => 'f\t/a/$i').join('\n');
      final result = parseRemoteSearch(output, base: '/a', maxHits: 3);

      expect(result.hits, hasLength(3));
      expect(result.truncated, isTrue);
    });

    test('untagged noise is ignored', () {
      expect(parseRemoteSearch('some stray line\n', base: '/a').hits, isEmpty);
      expect(parseRemoteSearch('', base: '/a').hits, isEmpty);
    });
  });

  group('searchSudoFailure', () {
    // The marker list is ported from `sftpReadError` (`ui/AppViewModel.kt:9676`) and shared with
    // every other privileged exec on the SFTP screen, so a marker cannot be added to one call site
    // and missed by another.

    test('a refusal is returned as the complaint to show', () {
      expect(
        searchSudoFailure('sudo: 3 incorrect password attempts\n'),
        'sudo: 3 incorrect password attempts',
      );
      expect(
        searchSudoFailure('sam is not in the sudoers file.\n'),
        'sam is not in the sudoers file.',
      );
    });

    test('a search that simply ran is not a failure', () {
      expect(searchSudoFailure('f\t/etc/passwd\n'), isNull);
      expect(searchSudoFailure(''), isNull);
    });

    test('leading blank lines do not hide the complaint', () {
      // sudo's lecture and prompt suppression both leave blank lines ahead of the real message.
      expect(searchSudoFailure('\n\n  permission denied\n'), 'permission denied');
    });

    test('a tagged hit is data, however much its name reads like an error', () {
      // The whole result set would otherwise vanish behind one unluckily named file, and the first
      // hit is exactly where that would bite.
      expect(searchSudoFailure('f\t/srv/no such thing.txt\nf\t/srv/b.txt\n'), isNull);
      expect(searchSudoFailure('d\t/srv/permission denied\n'), isNull);
    });

    test('the case the host chose does not matter', () {
      expect(searchSudoFailure('Permission Denied\n'), 'Permission Denied');
    });

    test('the whole-output check is available where output is not path data', () {
      // Compression and archive scripts fail several lines in, after their own progress output.
      expect(hasSudoFailureMarker('adding a\nadding b\npermission denied\n'), isTrue);
      expect(hasSudoFailureMarker('adding a\nadding b\n'), isFalse);
    });
  });

  group('sudo file access', () {
    // Real output shape, captured from the lab on sudo's first use in a session.
    const lecture =
        '\nWe trust you have received the usual lecture from the local System\n'
        'Administrator. It usually boils down to these three things:\n\n'
        '    #1) Respect the privacy of others.\n'
        '    #2) Think before you type.\n'
        '    #3) With great power comes great responsibility.\n\n'
        'For security reasons, the password you type will not be visible.\n\n';

    test('the read marker separates sudo chatter from the file', () {
      // Without this the lecture would be prepended to the file, land in the editor, and be
      // written back on save. Observed against a real host, not hypothetical.
      final output = '$lecture$sudoOutputMarker\nlisten 8080\nmode strict\n';

      expect(parseSudoRead(output), 'listen 8080\nmode strict\n');
    });

    test('a file that really is empty is not confused with a refusal', () {
      // Empty content and "sudo said no" have to stay distinguishable, or an unreadable file looks
      // like an empty one and saving it would truncate the original.
      expect(parseSudoRead('$sudoOutputMarker\n'), '');
      expect(parseSudoRead('sudo: a password is required\n'), isNull);
      expect(parseSudoRead(''), isNull);
    });

    test('the file keeps its own leading blank lines', () {
      expect(parseSudoRead('$sudoOutputMarker\n\n\n# comment\n'), '\n\n# comment\n');
    });

    test('the read command elevates and quotes the path', () {
      final command = sudoReadCommand('/etc/; rm -rf ~', 'pw');
      expect(command, contains('sudo -S'));
      expect(command, contains('cat --'));
      expect(command, isNot(contains('rm -rf ~ ')));
    });

    test('the write command copies into place and removes the temp copy', () {
      // Leaving a readable copy of a protected file in /tmp would quietly widen access to it, so
      // the removal is part of the same command rather than a follow-up that might not run.
      final command = sudoWriteCommand('/tmp/.omniterm-save-1', '/etc/thing.conf', 'pw');

      expect(command, contains('cp -f --'));
      expect(command, contains('wc -c <'));
      expect(command, contains('rm -f --'));
      // `;` before rm, not `&&`: the temp copy goes even when the copy into place failed.
      expect(command, contains("; rm -f --"));
    });

    test('the written size is the last number, not the first', () {
      // sudo's lecture and any warning come first; the count is the last thing printed. Taking the
      // first number would report a line number from a warning as the file size.
      expect(parseSudoWriteSize('${lecture}20\n'), 20);
      expect(parseSudoWriteSize('cp: preserving permissions: ignored\n40\n'), 40);
    });

    test('no number at all is -1, which judgeSave reports as unconfirmed', () {
      // Not 0: that would be indistinguishable from having written an empty file.
      expect(parseSudoWriteSize('sudo: a password is required\n'), -1);
      expect(parseSudoWriteSize(''), -1);
    });

    test('the temp path is somewhere any login can write', () {
      expect(sudoTempPath(), startsWith('/tmp/.omniterm-save-'));
    });
  });
}
