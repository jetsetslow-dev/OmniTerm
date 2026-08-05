import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/shares/remote_fs_client.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/domain/file_edit.dart';
import 'package:omniterm/domain/sftp_sort.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';

import 'support/fake_secure_storage.dart';

/// A shell that records what it was asked and replays a staged answer.
class FakeShell implements SshTransport {
  FakeShell(this._output);

  FakeShell.failing(String message) : _output = '', _failure = message;

  final String _output;
  String? _failure;

  final List<String> commands = [];

  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) async {
    commands.add(command);
    if (_failure != null) throw Exception(_failure);
    return _output;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// An in-memory remote filesystem: a map of directory path to its entries.
class FakeFsClient extends RemoteFsClient {
  FakeFsClient({this.homePath = '/home/root', Map<String, List<SftpFile>>? tree})
    : tree = tree ?? {};

  final String homePath;
  final Map<String, List<SftpFile>> tree;

  final List<String> listed = [];
  final List<String> created = [];
  final List<String> deleted = [];
  final List<(String, String)> renamed = [];
  final List<String> uploaded = [];

  /// Path to contents, for the editor.
  final Map<String, String> files = {};

  /// What `writeText` reports the remote size to be. Null means "the real byte count", which is
  /// what a healthy server does; anything else lets a test stage a save that did not land.
  int? reportedSizeOverride;

  bool textEditingSupported = true;
  final List<(String, String)> written = [];

  /// Paths whose operation throws.
  Set<String> failFor = {};

  @override
  Future<String> home() async => homePath;

  @override
  @override
  bool get supportsTextEditing => textEditingSupported;

  @override
  Future<String> readText(String path, {int maxBytes = 512 * 1024}) async {
    if (failFor.contains(path)) throw Exception('read refused');
    final content = files[path];
    if (content == null) throw Exception('no such file');
    return content.length <= maxBytes ? content : content.substring(0, maxBytes);
  }

  @override
  Future<int> writeText(String path, String content) async {
    if (failFor.contains(path)) throw Exception('write refused');
    written.add((path, content));
    files[path] = content;
    return reportedSizeOverride ?? content.length;
  }

  @override
  Future<List<SftpFile>> list(String path) async {
    listed.add(path);
    if (failFor.contains(path)) throw Exception('permission denied: $path');
    return tree[path] ?? const [];
  }

  @override
  Future<void> mkdir(String path) async {
    if (failFor.contains(path)) throw Exception('cannot create $path');
    created.add(path);
  }

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) async {
    renamed.add((oldPath, newPath));
  }

  @override
  Future<void> delete(String path, {required bool isDirectory}) async {
    if (failFor.contains(path)) throw Exception('cannot delete $path');
    deleted.add(path);
  }

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) async {
    if (failFor.contains(path)) throw Exception('read failed');
    onProgress?.call(50, 100);
    onProgress?.call(100, 100);
    return 100;
  }

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) async {
    if (failFor.contains(path)) throw Exception('write failed');
    uploaded.add(path);
    onProgress?.call(totalBytes, totalBytes);
  }
}

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({required String name, String status = 'online'}) => Server(
    id: 0,
    name: name,
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    authPassword: 'pw',
    sudoPassword: '',
    notes: '',
    keepAlive: 30,
    sshCompression: false,
    persistentSession: false,
    proxyCommand: '',
    proxyType: 'none',
    proxyHost: '',
    proxyPort: 0,
    proxyUser: '',
    proxyPassword: '',
    agentForwarding: false,
    healthScore: 100,
    lastLatency: 0,
    status: status,
    authStatus: 'ok',
  );

  SftpFile entry(String name, {bool dir = false, int size = 10, int modified = 0}) =>
      SftpFile(name: name, isDirectory: dir, size: size, modDate: '', modTimeSeconds: modified);

  FakeFsClient homeTree() => FakeFsClient(
    tree: {
      '/home/root': [
        entry('docs', dir: true),
        entry('notes.txt', size: 120),
        entry('.hidden', size: 5),
      ],
      '/home/root/docs': [entry('report.pdf', size: 900)],
    },
  );

  Future<SftpViewModel> boot({RemoteFsClient? client, SshTransport? shell}) async {
    await app.start();
    await Future<void>.delayed(Duration.zero);
    return SftpViewModel(
      app,
      fsClientFor: client == null ? null : (_) async => client,
      transport: shell,
    );
  }

  Future<SftpViewModel> booted(FakeFsClient client, {SshTransport? shell}) async {
    await repo.insertServer(server(name: 'nas'));
    final vm = await boot(client: client, shell: shell);
    await Future<void>.delayed(Duration.zero);
    await vm.start();
    return vm;
  }

  group('listing', () {
    test('the first open resolves the remote home', () async {
      final client = homeTree();
      final vm = await booted(client);

      expect(vm.path, '/home/root');
      expect(client.listed, contains('/home/root'));
      vm.dispose();
    });

    test('hidden files are filtered until asked for', () async {
      final vm = await booted(homeTree());

      expect(vm.visibleEntries.map((e) => e.name), isNot(contains('.hidden')));
      vm.showHidden = true;
      expect(vm.visibleEntries.map((e) => e.name), contains('.hidden'));
      vm.dispose();
    });

    test('search narrows locally, without refetching', () async {
      final client = homeTree();
      final vm = await booted(client);
      final listings = client.listed.length;

      vm.searchText = 'notes';
      expect(vm.visibleEntries.map((e) => e.name), ['notes.txt']);
      expect(client.listed.length, listings, reason: 'filtering is local');
      vm.dispose();
    });

    test('sorting is local too', () async {
      final client = homeTree();
      final vm = await booted(client);
      final listings = client.listed.length;

      vm.sortOption = SftpSortOption.sizeDesc;
      expect(client.listed.length, listings);
      expect(vm.visibleEntries.first.isDirectory, isTrue, reason: 'directories still lead');
      vm.dispose();
    });

    test('opening a directory navigates into it', () async {
      final vm = await booted(homeTree());

      await vm.open(entry('docs', dir: true));
      expect(vm.path, '/home/root/docs');
      expect(vm.visibleEntries.map((e) => e.name), ['report.pdf']);
      vm.dispose();
    });

    test('tapping a file does not navigate', () async {
      final vm = await booted(homeTree());
      await vm.open(entry('notes.txt'));
      expect(vm.path, '/home/root');
      vm.dispose();
    });

    test('going up walks the tree and stops at the root', () async {
      final client = FakeFsClient(
        homePath: '/a/b/c',
        tree: {'/a/b/c': [], '/a/b': [], '/a': [], '/': []},
      );
      final vm = await booted(client);

      await vm.goUp();
      expect(vm.path, '/a/b');
      await vm.goUp();
      expect(vm.path, '/a');
      await vm.goUp();
      expect(vm.path, '/');
      await vm.goUp();
      expect(vm.path, '/', reason: 'the root has nowhere above it');
      vm.dispose();
    });

    test('breadcrumbs describe the current path', () async {
      final vm = await booted(homeTree());
      expect(vm.breadcrumbTrail.map((c) => c.name), ['/', 'home', 'root']);
      vm.dispose();
    });
  });

  group('failures', () {
    test('a listing failure clears the rows rather than leaving the old ones', () async {
      // Leaving the previous directory's rows under a path that failed to open invites acting on
      // the wrong files.
      final client = homeTree()..failFor = {'/home/root/docs'};
      final vm = await booted(client);
      expect(vm.visibleEntries, isNotEmpty);

      await vm.openPath('/home/root/docs');

      expect(vm.error, contains('permission denied'));
      expect(vm.visibleEntries, isEmpty);
      vm.dispose();
    });

    test('without a client it says so rather than showing an empty directory', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      await vm.openPath('/etc');

      expect(vm.canBrowse, isFalse);
      expect(vm.error, isNotNull);
      vm.dispose();
    });

    test('a listing for a host the user left is discarded', () async {
      await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      final client = homeTree();
      final vm = await boot(client: client);
      await Future<void>.delayed(Duration.zero);

      // Switching host clears state; the in-flight listing must not repopulate it.
      app.selectedServerId = bId;
      await Future<void>.delayed(Duration.zero);
      expect(vm.path, isNotEmpty, reason: 'the new host loaded its own listing');
      vm.dispose();
    });
  });

  group('selection', () {
    test('rows toggle, and select-all covers only what is visible', () async {
      final vm = await booted(homeTree());

      vm.toggleSelected('notes.txt');
      expect(vm.selectedNames, {'notes.txt'});
      vm.toggleSelected('notes.txt');
      expect(vm.hasSelection, isFalse);

      vm.selectAllVisible();
      expect(vm.selectedNames, {
        'docs',
        'notes.txt',
      }, reason: 'the hidden file is not on screen, so it is not selected');
      vm.dispose();
    });

    test('navigating clears the selection', () async {
      // Carrying a selection into another directory would let a delete act on names that happen to
      // match there.
      final vm = await booted(homeTree());
      vm.selectAllVisible();

      await vm.open(entry('docs', dir: true));
      expect(vm.hasSelection, isFalse);
      vm.dispose();
    });
  });

  group('file operations', () {
    test('creating a directory rejects unusable names', () async {
      final client = homeTree();
      final vm = await booted(client);

      for (final name in ['', '  ', '.', '..', 'a/b']) {
        expect(await vm.createDirectory(name), isNotNull, reason: name);
      }
      expect(client.created, isEmpty);
      vm.dispose();
    });

    test('creating a directory refuses to clash with an existing entry', () async {
      final client = homeTree();
      final vm = await booted(client);

      expect(await vm.createDirectory('docs'), contains('already exists'));
      expect(client.created, isEmpty);
      vm.dispose();
    });

    test('creating a directory writes it and refreshes', () async {
      final client = homeTree();
      final vm = await booted(client);
      final listings = client.listed.length;

      expect(await vm.createDirectory('new'), isNull);
      expect(client.created, ['/home/root/new']);
      expect(
        client.listed.length,
        greaterThan(listings),
        reason: 'the listing must reflect what the server did, not what was asked',
      );
      vm.dispose();
    });

    test('renaming validates the same way', () async {
      final client = homeTree();
      final vm = await booted(client);

      expect(await vm.rename(entry('notes.txt'), '..'), isNotNull);
      expect(await vm.rename(entry('notes.txt'), 'docs'), contains('already exists'));
      expect(client.renamed, isEmpty);

      expect(await vm.rename(entry('notes.txt'), 'renamed.txt'), isNull);
      expect(client.renamed, [('/home/root/notes.txt', '/home/root/renamed.txt')]);
      vm.dispose();
    });

    test('renaming to the same name is a no-op, not an error', () async {
      final client = homeTree();
      final vm = await booted(client);
      expect(await vm.rename(entry('notes.txt'), 'notes.txt'), isNull);
      expect(client.renamed, isEmpty);
      vm.dispose();
    });

    test('deleting removes every selected entry', () async {
      final client = homeTree();
      final vm = await booted(client);

      await vm.deleteEntries([entry('notes.txt'), entry('docs', dir: true)]);
      expect(client.deleted, ['/home/root/notes.txt', '/home/root/docs']);
      expect(vm.status, contains('2 items'));
      vm.dispose();
    });

    test('a failed delete surfaces the error', () async {
      final client = homeTree()..failFor = {'/home/root/notes.txt'};
      final vm = await booted(client);

      await vm.deleteEntries([entry('notes.txt')]);
      expect(vm.error, contains('cannot delete'));
      vm.dispose();
    });
  });

  group('bookmarks', () {
    test('a host with none gets a useful default list', () async {
      final vm = await booted(homeTree());
      expect(vm.bookmarks, SftpViewModel.defaultBookmarks);
      vm.dispose();
    });

    test('toggling adds, removes and persists in the Kotlin format', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot(client: homeTree());
      await Future<void>.delayed(Duration.zero);

      await vm.start();
      await vm.toggleBookmark('/srv/www');
      await vm.toggleBookmark('/opt/app');
      expect(vm.isBookmarked('/srv/www'), isTrue);

      // The Kotlin's storage format, so an upgraded install reads its existing bookmarks.
      final raw = await repo.getSetting('sftp_bookmarks_$id');
      expect(raw, contains(SftpViewModel.bookmarkSeparator));
      expect(raw!.split(SftpViewModel.bookmarkSeparator), containsAll(['/srv/www', '/opt/app']));

      await vm.toggleBookmark('/srv/www');
      expect(vm.isBookmarked('/srv/www'), isFalse);
      vm.dispose();
    });

    test('a path is bookmarked regardless of trailing slashes', () async {
      final vm = await booted(homeTree());
      await vm.toggleBookmark('/srv/www/');
      expect(vm.isBookmarked('/srv/www'), isTrue);
      expect(vm.bookmarks, contains('/srv/www'));
      vm.dispose();
    });

    test('opening a bookmark jumps there and switches to the browser', () async {
      final client = homeTree()..tree['/etc'] = [entry('hosts')];
      final vm = await booted(client);

      await vm.openBookmark('/etc');
      expect(vm.activeTab, SftpTab.files);
      expect(vm.path, '/etc');
      vm.dispose();
    });

    test('bookmarks are per host', () async {
      // /srv/www is meaningful on one machine and absent on the next.
      final aId = await repo.insertServer(server(name: 'a'));
      final bId = await repo.insertServer(server(name: 'b'));
      await repo.insertSetting('sftp_bookmarks_$aId', '/srv/www');
      await repo.insertSetting('sftp_bookmarks_$bId', '/opt/app');

      final vm = await boot(client: homeTree());
      app.selectedServerId = aId;
      await vm.start();
      await Future<void>.delayed(Duration.zero);
      expect(vm.bookmarks, ['/srv/www']);

      app.selectedServerId = bId;
      await Future<void>.delayed(Duration.zero);
      expect(vm.bookmarks, ['/opt/app']);
      vm.dispose();
    });
  });

  group('transfers', () {
    test('a download reports progress and finishes', () async {
      final vm = await booted(homeTree());
      final sink = StreamController<List<int>>()..stream.listen((_) {});

      await vm.download(entry('notes.txt', size: 100), sink.sink);

      expect(vm.transfers, hasLength(1));
      expect(vm.transfers.single.status, TransferStatus.done);
      expect(vm.transfers.single.progress, 1.0);
      await sink.close();
      vm.dispose();
    });

    test('a failed download is kept and shows why', () async {
      final client = homeTree()..failFor = {'/home/root/notes.txt'};
      final vm = await booted(client);
      final sink = StreamController<List<int>>()..stream.listen((_) {});

      await vm.download(entry('notes.txt'), sink.sink);

      expect(vm.transfers.single.status, TransferStatus.failed);
      expect(vm.transfers.single.error, contains('read failed'));
      await sink.close();
      vm.dispose();
    });

    test('an upload never silently overwrites', () async {
      // Replacing a file the user did not mean to touch is unrecoverable.
      final client = homeTree();
      final vm = await booted(client);

      await vm.upload('notes.txt', Stream.value([1, 2, 3]), 3);

      expect(client.uploaded, ['/home/root/notes (2).txt']);
      vm.dispose();
    });

    test('an upload to a free name keeps that name', () async {
      final client = homeTree();
      final vm = await booted(client);

      await vm.upload('fresh.txt', Stream.value([1]), 1);
      expect(client.uploaded, ['/home/root/fresh.txt']);
      vm.dispose();
    });

    test('an unknown size gives an indeterminate progress bar', () async {
      // A determinate bar showing a made-up fraction is worse than an honest spinner.
      final vm = await booted(homeTree());
      final sink = StreamController<List<int>>()..stream.listen((_) {});
      await vm.download(entry('notes.txt', size: 0), sink.sink);
      expect(vm.transfers.single.progress, isNull);
      await sink.close();
      vm.dispose();
    });

    test('finished transfers clear, running ones stay', () async {
      final vm = await booted(homeTree());
      final sink = StreamController<List<int>>()..stream.listen((_) {});
      await vm.download(entry('notes.txt'), sink.sink);
      expect(vm.transfers, hasLength(1));

      vm.clearFinishedTransfers();
      expect(vm.transfers, isEmpty);
      await sink.close();
      vm.dispose();
    });
  });

  group('tabs', () {
    test('the browser tab needs an online host; the others do not', () async {
      await repo.insertServer(server(name: 'nas', status: 'offline'));
      final vm = await boot(client: homeTree());
      await Future<void>.delayed(Duration.zero);

      vm.activeTab = SftpTab.files;
      expect(vm.activeTab, SftpTab.bookmarks, reason: 'there is nothing to browse');

      vm.activeTab = SftpTab.transfers;
      expect(vm.activeTab, SftpTab.transfers);
      vm.dispose();
    });
  });

  group('the text editor', () {
    FakeFsClient editableTree() {
      final client = homeTree();
      client.files['/home/root/notes.txt'] = 'listen 8080\n';
      return client;
    }

    test('a file is read for editing', () async {
      final vm = await booted(editableTree());

      expect(await vm.readForEditing(entry('notes.txt', size: 120)), 'listen 8080\n');
      expect(vm.canEditText, isTrue);
      vm.dispose();
    });

    test('a connection that cannot edit says so instead of opening an empty editor', () async {
      // Convention 4: absent means the feature is off and the screen says why. An editor that
      // opened blank over a share it cannot write would invite someone to retype a file into a
      // void.
      final client = editableTree()..textEditingSupported = false;
      final vm = await booted(client);

      expect(await vm.readForEditing(entry('notes.txt')), isNull);
      expect(vm.canEditText, isFalse);
      expect(vm.error, contains('not supported on this connection'));
      expect(
        vm.error,
        isNot(contains('credential')),
        reason: 'the connection is fine; blaming its credentials sends the user to fix nothing',
      );
      vm.dispose();
    });

    test('a file too large to edit on a phone is refused with its size', () async {
      final vm = await booted(editableTree());

      expect(await vm.readForEditing(entry('huge.log', size: 40 * 1024 * 1024)), isNull);
      expect(vm.error, contains('too large'));
      expect(vm.error, contains('40.0 MB'), reason: 'the number is what makes the refusal useful');
      vm.dispose();
    });

    test('a save the server confirms is reported as confirmed', () async {
      final client = editableTree();
      final vm = await booted(client);

      final result = await vm.saveText(entry('notes.txt'), 'listen 9090\n');

      expect(result.outcome, FileSaveOutcome.confirmed);
      expect(result.canClose, isTrue);
      expect(client.files['/home/root/notes.txt'], 'listen 9090\n');
      expect(vm.status, contains('12 bytes confirmed'));
      vm.dispose();
    });

    test('a save the server contradicts keeps the edits and refuses to close', () async {
      // The whole reason the size is read back. SFTP reports success against a full disk, a quota,
      // or a path that resolved somewhere else; closing the editor on that would throw away the
      // only remaining copy of the user's work.
      final client = editableTree()..reportedSizeOverride = 3;
      final vm = await booted(client);

      final result = await vm.saveText(entry('notes.txt'), 'listen 9090\n');

      expect(result.outcome, FileSaveOutcome.mismatch);
      expect(result.canClose, isFalse, reason: 'the editor must keep the unsaved text');
      expect(vm.error, contains('server reports 3 bytes, expected 12'));
      expect(vm.error, contains('try saving again'));
      vm.dispose();
    });

    test(
      'a save whose size cannot be read back says so rather than claiming confirmation',
      () async {
        final client = editableTree()..reportedSizeOverride = -1;
        final vm = await booted(client);

        final result = await vm.saveText(entry('notes.txt'), 'listen 9090\n');

        expect(result.outcome, FileSaveOutcome.unconfirmed);
        expect(
          result.canClose,
          isTrue,
          reason: 'the write did not fail, so the edits are not lost',
        );
        expect(vm.status, contains('could not be read back'));
        vm.dispose();
      },
    );

    test('a failed write is an error, not a silent no-op', () async {
      final client = editableTree()..failFor = {'/home/root/notes.txt'};
      final vm = await booted(client);

      final result = await vm.saveText(entry('notes.txt'), 'listen 9090\n');

      expect(result.outcome, FileSaveOutcome.failed);
      expect(result.canClose, isFalse);
      expect(vm.error, contains('Save failed'));
      vm.dispose();
    });
  });

  group('folder size', () {
    /// A shell that answers `du` with whatever the test stages.
    FakeShell shell({String output = '1.2G\t/home/root/docs\n'}) => FakeShell(output);

    test('a directory is measured with du', () async {
      // A listing shows a directory's *index* size — "4.0 KB" for a folder holding 80 GB — so this
      // is the answer to the question people open a file browser to ask.
      final ssh = shell();
      final vm = await booted(homeTree(), shell: ssh);

      expect((await vm.folderSize(entry('docs', dir: true)))!.size, '1.2G');
      expect(ssh.commands.single, contains("du -shx -- '/home/root/docs'"));
      vm.dispose();
    });

    test('without a shell the action is not offered at all', () async {
      // Convention 4: absent means the feature is off, not that it fails on tap.
      final vm = await booted(homeTree());

      expect(vm.canMeasureSize, isFalse);
      expect(await vm.folderSize(entry('docs', dir: true)), isNull);
      vm.dispose();
    });

    test('a host with no du says so rather than reporting nothing', () async {
      // Zero would read as "this folder is empty", which is a different and wrong statement.
      final vm = await booted(
        homeTree(),
        shell: shell(output: 'sh: du: not found\n---DU-FAILED---'),
      );

      expect(await vm.folderSize(entry('docs', dir: true)), isNull);
      expect(vm.error, contains('Could not measure'));
      vm.dispose();
    });

    test('a shell failure is reported, not swallowed', () async {
      final vm = await booted(homeTree(), shell: FakeShell.failing('connection lost'));

      expect(await vm.folderSize(entry('docs', dir: true)), isNull);
      expect(vm.error, contains('connection lost'));
      vm.dispose();
    });
  });

  group('searching the host', () {
    test('results come back tagged, and the folder itself is not one of them', () async {
      final ssh = FakeShell('d\t/home/root\nf\t/home/root/notes.txt\nd\t/home/root/docs\n');
      final vm = await booted(homeTree(), shell: ssh);

      await vm.searchHost('o');

      expect(ssh.commands.single, contains("-iname '*o*'"));
      expect(vm.searchHits, hasLength(2), reason: 'the base folder is not a result');
      expect(vm.searchHits!.last.isDirectory, isTrue);
      expect(vm.searchTruncated, isFalse);
      vm.dispose();
    });

    test('nothing found is said differently from not having asked', () async {
      // Null and empty are different facts, and the screen shows each of them differently.
      final vm = await booted(homeTree(), shell: FakeShell(''));

      expect(vm.searchHits, isNull, reason: 'nothing has been asked yet');
      await vm.searchHost('zzz');
      expect(vm.searchHits, isEmpty, reason: 'asked, and there is nothing there');
      vm.dispose();
    });

    test('an empty query does nothing rather than walking the whole host', () async {
      final ssh = FakeShell('');
      final vm = await booted(homeTree(), shell: ssh);

      await vm.searchHost('   ');

      expect(ssh.commands, isEmpty);
      vm.dispose();
    });

    test('opening a file hit lands in the folder that contains it', () async {
      // The browser works on a directory, so jumping to a file means opening its parent — anything
      // else would show a listing the file is not in.
      final client = homeTree();
      final vm = await booted(client, shell: FakeShell('f\t/home/root/docs/report.pdf\n'));
      await vm.searchHost('report');

      await vm.openSearchHit(vm.searchHits!.single);

      expect(vm.path, '/home/root/docs');
      expect(vm.searchHits, isNull, reason: 'the results give way to the listing');
      vm.dispose();
    });

    test('opening a directory hit opens that directory', () async {
      final vm = await booted(homeTree(), shell: FakeShell('d\t/home/root/docs\n'));
      await vm.searchHost('docs');

      await vm.openSearchHit(vm.searchHits!.single);

      expect(vm.path, '/home/root/docs');
      vm.dispose();
    });

    test('a shell failure is reported rather than looking like no results', () async {
      final vm = await booted(homeTree(), shell: FakeShell.failing('connection lost'));

      await vm.searchHost('x');

      expect(vm.searchHits, isNull);
      expect(vm.error, contains('Search failed'));
      vm.dispose();
    });

    test('without a shell searching is not offered', () async {
      final vm = await booted(homeTree());

      expect(vm.canSearchHost, isFalse);
      await vm.searchHost('x');
      expect(vm.searchHits, isNull);
      vm.dispose();
    });
  });

  group('sudo mode', () {
    test('it is not offered without a shell', () async {
      final vm = await booted(homeTree());
      expect(vm.canUseSudo, isFalse);
      vm.dispose();
    });

    test('opening a file goes over an exec channel, not SFTP', () async {
      // SFTP has no concept of elevation, so a protected file has to come back another way.
      final client = homeTree();
      client.files['/home/root/notes.txt'] = 'unused';
      final ssh = FakeShell('---OMNITERM-BEGIN---\nroot-only contents\n');
      final vm = await booted(client, shell: ssh);
      vm.sudoMode = true;

      expect(await vm.readForEditing(entry('notes.txt', size: 20)), 'root-only contents\n');
      expect(ssh.commands.single, contains('cat --'));
      vm.dispose();
    });

    test('a refusal is shown rather than opening an empty editor', () async {
      // Empty content and "sudo said no" must stay distinguishable: saving the former would
      // truncate a file the user could not even read.
      final client = homeTree();
      final vm = await booted(client, shell: FakeShell('sudo: a password is required\n'));
      vm.sudoMode = true;

      expect(await vm.readForEditing(entry('notes.txt', size: 20)), isNull);
      expect(vm.error, contains('password is required'));
      vm.dispose();
    });

    test('saving stages a temp copy and confirms the size the server ends up with', () async {
      final client = homeTree();
      // 20 bytes — the exact count the lab returned for this string through the same command.
      final ssh = FakeShell('20\n');
      final vm = await booted(client, shell: ssh);
      vm.sudoMode = true;

      final result = await vm.saveText(entry('notes.txt'), 'edited by sudo path\n');

      expect(result.outcome, FileSaveOutcome.confirmed);
      // Staged through a path the ordinary login can write…
      expect(client.written.single.$1, startsWith('/tmp/.omniterm-save-'));
      // …then copied into place and cleaned up by the privileged command.
      expect(ssh.commands.single, contains('cp -f --'));
      expect(ssh.commands.single, contains('rm -f --'));
      vm.dispose();
    });

    test('a sudo write that reports nothing is unconfirmed, not a success', () async {
      final vm = await booted(homeTree(), shell: FakeShell('sudo: a password is required\n'));
      vm.sudoMode = true;

      final result = await vm.saveText(entry('notes.txt'), 'x');

      expect(result.outcome, FileSaveOutcome.unconfirmed);
      expect(result.message, contains('could not be read back'));
      vm.dispose();
    });

    test('with sudo off nothing goes near a shell', () async {
      final client = homeTree();
      client.files['/home/root/notes.txt'] = 'plain';
      final ssh = FakeShell('');
      final vm = await booted(client, shell: ssh);

      await vm.readForEditing(entry('notes.txt', size: 5));
      await vm.saveText(entry('notes.txt'), 'plain2');

      expect(ssh.commands, isEmpty, reason: 'the ordinary path is still SFTP');
      vm.dispose();
    });
  });
}
