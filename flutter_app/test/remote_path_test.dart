import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/domain/remote_path.dart';
import 'package:omniterm/domain/sftp_sort.dart';

void main() {
  group('normalisePath', () {
    test('collapses duplicate separators and strips a trailing one', () {
      // `//srv//www/` and `/srv/www` name the same directory; treating them as different breaks
      // breadcrumb highlighting and "already here" checks.
      expect(normalisePath('//srv//www/'), '/srv/www');
      expect(normalisePath('/srv/www'), '/srv/www');
      expect(normalisePath('/'), '/');
      expect(normalisePath('//'), '/');
      expect(normalisePath(''), '/');
    });
  });

  group('parentPath', () {
    test('walks up one level', () {
      expect(parentPath('/srv/www/html'), '/srv/www');
      expect(parentPath('/srv'), '/');
    });

    test('the root is its own parent', () {
      // "Up" from the root must land somewhere navigable, not at an empty path.
      expect(parentPath('/'), '/');
      expect(parentPath(''), '/');
    });

    test('a trailing slash does not add a phantom level', () {
      expect(parentPath('/srv/www/'), '/srv');
    });
  });

  group('joinPath', () {
    test('never doubles or drops the separator', () {
      expect(joinPath('/srv', 'www'), '/srv/www');
      expect(joinPath('/srv/', 'www'), '/srv/www');
      expect(joinPath('/', 'etc'), '/etc');
      expect(joinPath('', 'etc'), '/etc');
    });
  });

  group('baseName', () {
    test('returns the last component', () {
      expect(baseName('/srv/www/index.html'), 'index.html');
      expect(baseName('/srv/www/'), 'www');
      expect(baseName('/'), '/');
    });
  });

  group('resolveTypedPath', () {
    // The address box, ported from the editable path field in `ui/SftpScreen.kt:1806`. Flutter had
    // breadcrumbs and no way to type a destination at all, so a folder had to be walked to.
    String? typed(String text, {String current = '/srv/www'}) =>
        resolveTypedPath(current: current, typed: text);

    test('an absolute path goes where it says', () {
      expect(typed('/var/log'), '/var/log');
    });

    test('it is normalised on the way, like any other path', () {
      expect(typed('/var//log/'), '/var/log');
    });

    test('surrounding space is not part of the path', () {
      // Space is legal in a filename, but a leading or trailing one here is a paste artefact far
      // more often than it is a directory the user means.
      expect(typed('  /var/log  '), '/var/log');
    });

    test('a relative entry resolves against where you are', () {
      // The box is prefilled with the current directory, so `docs` means the same thing it would in
      // a shell. Sent unresolved it would list the SFTP session's working directory, which the user
      // cannot see.
      expect(typed('docs'), '/srv/www/docs');
      expect(typed('docs/img'), '/srv/www/docs/img');
    });

    test('a relative entry with no current directory falls back to the root', () {
      // Before the first listing resolves, there is nothing to resolve against.
      expect(typed('etc', current: ''), '/etc');
    });

    test('an emptied box is a change of mind, not a jump to the root', () {
      // Going to `/` from deep in a tree is a surprising way to lose your place.
      expect(typed(''), isNull);
      expect(typed('   '), isNull);
    });

    test('the root itself is still reachable by typing it', () {
      expect(typed('/'), '/');
    });
  });

  group('breadcrumbs', () {
    test('start at the root and end at the path itself', () {
      final crumbs = breadcrumbs('/srv/www/html');
      expect(crumbs.map((c) => c.name), ['/', 'srv', 'www', 'html']);
      expect(crumbs.map((c) => c.path), ['/', '/srv', '/srv/www', '/srv/www/html']);
    });

    test('the root alone is a single crumb', () {
      expect(breadcrumbs('/').map((c) => c.path), ['/']);
    });

    test('every crumb is a path that can actually be opened', () {
      for (final crumb in breadcrumbs('//srv//www/')) {
        expect(crumb.path, normalisePath(crumb.path));
      }
    });
  });

  group('isWithin', () {
    test('a directory contains itself and its descendants', () {
      expect(isWithin('/srv', '/srv'), isTrue);
      expect(isWithin('/srv', '/srv/www'), isTrue);
      expect(isWithin('/', '/anything'), isTrue);
    });

    test('a sibling sharing a name prefix is not inside', () {
      // A plain startsWith would say yes, and a move would then be refused — or worse, allowed
      // into a directory the user did not name.
      expect(isWithin('/srv/www', '/srv/www-old'), isFalse);
      expect(isWithin('/srv/www', '/srv/wwwx/deep'), isFalse);
    });

    test('a parent is not inside its child', () {
      expect(isWithin('/srv/www', '/srv'), isFalse);
    });
  });

  group('validateFileName', () {
    test('accepts an ordinary name, trimmed', () {
      expect(validateFileName('  notes.txt '), 'notes.txt');
    });

    test('rejects names that would act somewhere else', () {
      // Each of these either fails on the server or silently operates outside the current
      // directory — which is not where the user is looking.
      for (final name in ['', '   ', '.', '..', 'a/b', '/etc']) {
        expect(validateFileName(name), isNull, reason: name);
      }
    });

    test('allows a dotfile', () {
      expect(validateFileName('.bashrc'), '.bashrc');
    });
  });

  group('uniqueName', () {
    test('leaves a free name alone', () {
      expect(uniqueName('notes.txt', {'other.txt'}), 'notes.txt');
    });

    test('puts the counter before the extension', () {
      // Keeping the extension last is what makes the copy still open in the same application.
      expect(uniqueName('notes.txt', {'notes.txt'}), 'notes (2).txt');
      expect(uniqueName('notes.txt', {'notes.txt', 'notes (2).txt'}), 'notes (3).txt');
    });

    test('a name with no extension just gets the counter', () {
      expect(uniqueName('README', {'README'}), 'README (2)');
    });

    test('a dotfile keeps its leading dot', () {
      // `.bashrc` is a whole name, not an extension — ` (2).bashrc` would be wrong.
      expect(uniqueName('.bashrc', {'.bashrc'}), '.bashrc (2)');
    });

    test('only the last dot counts as the extension', () {
      expect(uniqueName('archive.tar.gz', {'archive.tar.gz'}), 'archive.tar (2).gz');
    });
  });

  group('sortEntries', () {
    SftpFile file(String name, {bool dir = false, int size = 0, int modified = 0}) =>
        SftpFile(name: name, isDirectory: dir, size: size, modDate: '', modTimeSeconds: modified);

    final entries = [
      file('zebra.txt', size: 10, modified: 300),
      file('Apple', dir: true, size: 4096, modified: 100),
      file('beta.txt', size: 500, modified: 200),
      file('alpha', dir: true, size: 4096, modified: 400),
    ];

    List<String> names(SftpSortOption option) =>
        sortEntries(entries, option).map((f) => f.name).toList();

    test('directories lead in every mode but files-first', () {
      for (final option in SftpSortOption.values) {
        final sorted = sortEntries(entries, option);
        final leadIsDirectory = sorted.first.isDirectory;
        expect(leadIsDirectory, option != SftpSortOption.typeFilesFirst, reason: option.name);
      }
    });

    test('name order is case-insensitive', () {
      expect(names(SftpSortOption.nameAsc), ['alpha', 'Apple', 'beta.txt', 'zebra.txt']);
      expect(names(SftpSortOption.nameDesc), ['Apple', 'alpha', 'zebra.txt', 'beta.txt']);
    });

    test('size and date order only within each group', () {
      // A directory's reported size is its inode's, not its contents'. Interleaving folders by
      // size would order them by a number that means nothing.
      expect(names(SftpSortOption.sizeDesc), ['alpha', 'Apple', 'beta.txt', 'zebra.txt']);
      expect(names(SftpSortOption.modifiedDesc), ['alpha', 'Apple', 'zebra.txt', 'beta.txt']);
      expect(names(SftpSortOption.modifiedAsc), ['Apple', 'alpha', 'beta.txt', 'zebra.txt']);
    });

    test('files-first inverts only the grouping', () {
      expect(names(SftpSortOption.typeFilesFirst), ['beta.txt', 'zebra.txt', 'alpha', 'Apple']);
    });

    test('equal keys fall back to name, so the order is stable', () {
      final tied = [file('b.txt', size: 100), file('a.txt', size: 100), file('c.txt', size: 100)];
      expect(sortEntries(tied, SftpSortOption.sizeDesc).map((f) => f.name), [
        'a.txt',
        'b.txt',
        'c.txt',
      ]);
    });

    test('sorting does not mutate the input', () {
      final original = [...entries];
      sortEntries(entries, SftpSortOption.sizeDesc);
      expect(entries.map((f) => f.name), original.map((f) => f.name));
    });
  });
}
