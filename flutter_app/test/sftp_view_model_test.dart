import 'dart:io';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/shares/remote_fs_client.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/domain/endpoint_bookmark.dart';
import 'package:omniterm/domain/file_edit.dart';
import 'package:omniterm/domain/sftp_sort.dart';
import 'package:omniterm/platform/device_file_store.dart';
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

  /// What was fed to each command's stdin, so a test can assert a sudo password went over the
  /// channel rather than into the command line, where `ps` and auditd would see it.
  final List<String?> stdins = [];

  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) async {
    commands.add(command);
    stdins.add(stdin);
    if (_failure != null) throw Exception(_failure);
    return _output;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A device file store that saves into a real temp directory.
///
/// Writes rather than records, so the batch download can be asserted on the files that actually
/// landed rather than on the calls it was asked to make — the difference between testing the
/// outcome and testing the mock.
class FakeDeviceFileStore extends DeviceFileStore {
  FakeDeviceFileStore(this.destination, {this.cancelFolder = false, this.failFor = const {}});

  final Directory destination;

  /// The user backing out of the folder chooser.
  final bool cancelFolder;

  /// Names whose save reports a failure, for the partial-batch case.
  final Set<String> failFor;

  int folderPicks = 0;

  @override
  Future<DeviceFolder?> pickFolder() async {
    folderPicks++;
    return cancelFolder ? null : DeviceFolder(destination.path);
  }

  @override
  Future<DeviceSaveResult> saveInto(DeviceFolder folder, String fileName, String sourcePath) async {
    if (failFor.contains(fileName)) {
      return const DeviceSaveResult(DeviceSaveOutcome.failed, error: 'disk full');
    }
    final target = File('${folder.handle as String}/$fileName');
    await target.writeAsBytes(await File(sourcePath).readAsBytes());
    return DeviceSaveResult(DeviceSaveOutcome.saved, location: target.path);
  }
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

  /// Held open by a test that needs a mutation to still be in flight when the next one is issued.
  Completer<void>? deleteGate;
  final List<(String, String)> renamed = [];
  final List<String> uploaded = [];
  int closeCalls = 0;

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
    await deleteGate?.future;
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

  @override
  void close() => closeCalls++;
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

  Server server({required String name, String status = 'online', String sudoPassword = ''}) =>
      Server(
        id: 0,
        name: name,
        host: '10.0.0.1',
        port: 22,
        username: 'root',
        serverColor: 'Default',
        authType: 'password',
        authPassword: 'pw',
        sudoPassword: sudoPassword,
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

  group('one mutation at a time', () {
    test('a second delete issued mid-flight is refused rather than interleaved', () async {
      final client = homeTree();
      final vm = await booted(client);

      final gate = Completer<void>();
      client.deleteGate = gate;
      final first = vm.deleteEntries([entry('notes.txt', size: 120)]);
      await Future<void>.delayed(Duration.zero);
      expect(vm.loading, isTrue, reason: 'the first delete is still running');

      // The second one arrives while the first holds the client — the case the menu gate stops in
      // the UI, and that _mutate has to stop for every other caller.
      await vm.deleteEntries([entry('.hidden', size: 5)]);
      expect(client.deleted, ['/home/root/notes.txt']);

      gate.complete();
      await first;
      expect(client.deleted, ['/home/root/notes.txt']);
      vm.dispose();
    });

    test('a delete issued after the first finished still runs', () async {
      final client = homeTree();
      final vm = await booted(client);

      await vm.deleteEntries([entry('notes.txt', size: 120)]);
      await vm.deleteEntries([entry('.hidden', size: 5)]);

      expect(client.deleted, ['/home/root/notes.txt', '/home/root/.hidden']);
      expect(vm.loading, isFalse);
      vm.dispose();
    });
  });

  group('listing', () {
    test('the first open resolves the remote home', () async {
      final client = homeTree();
      final vm = await booted(client);

      expect(vm.path, '/home/root');
      expect(client.listed, contains('/home/root'));
      vm.dispose();
    });

    test('a share opens its configured start path instead of the protocol root', () async {
      final client = FakeFsClient(
        tree: {
          '/fixture/nested': [entry('hello.txt')],
        },
      );
      await app.start();
      final vm = SftpViewModel(app, shareClientFor: (_) async => client);
      await vm.openShare(
        const NetworkShare(
          id: 7,
          name: 'WebDAV fixture',
          protocol: 'WEBDAV',
          address: 'nas.local',
          port: 8443,
          sharePath: '/fixture/nested/',
          workgroup: '',
          username: 'sam',
          password: 'pw',
          anonymous: false,
          useHttps: true,
          notes: '',
          lastChecked: 0,
          lastStatus: 'online',
        ),
      );

      expect(client.listed, ['/fixture/nested']);
      expect(vm.path, '/fixture/nested');
      expect(vm.visibleEntries.single.name, 'hello.txt');
      vm.dispose();
    });

    test('a share reuses one client through editor save and closes it', () async {
      final client = FakeFsClient(
        tree: {
          '/fixture': [entry('fixture.txt', size: 7)],
        },
      )..files['/fixture/fixture.txt'] = 'before\n';
      var resolutions = 0;
      await app.start();
      final vm = SftpViewModel(
        app,
        shareClientFor: (_) async {
          resolutions++;
          return client;
        },
      );
      await vm.openShare(
        const NetworkShare(
          id: 8,
          name: 'WebDAV fixture',
          protocol: 'WEBDAV',
          address: 'nas.local',
          port: 8443,
          sharePath: '/fixture',
          workgroup: '',
          username: 'sam',
          password: 'pw',
          anonymous: false,
          useHttps: true,
          notes: '',
          lastChecked: 0,
          lastStatus: 'online',
        ),
      );

      final fixture = vm.visibleEntries.single;
      expect(await vm.readForEditing(fixture), 'before\n');
      expect((await vm.saveText(fixture, 'after\n')).isError, isFalse);
      expect(await vm.readForEditing(fixture), 'after\n');
      expect(resolutions, 1);
      expect(client.closeCalls, 0);

      await vm.closeShare();
      expect(client.closeCalls, 1);
      vm.dispose();
      expect(client.closeCalls, 1);
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
      expect(raw, contains(bookmarkSeparator));
      expect(raw!.split(bookmarkSeparator), containsAll(['/srv/www', '/opt/app']));

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

  group('image preview', () {
    SftpFile img(String name, {int size = 100}) =>
        SftpFile(name: name, isDirectory: false, size: size, modDate: '2026-08-01');

    FakeFsClient imageTree() => FakeFsClient(
      tree: {
        '/home/root': [img('cat.png'), img('notes.txt'), img('huge.png', size: 128 * 1024 * 1024)],
      },
    );

    test('an image is fetched into memory and shown', () async {
      final vm = await booted(imageTree());

      await vm.openImagePreview(img('cat.png'));

      expect(vm.imagePreview!.bytes, isNotNull);
      expect(vm.imagePreview!.error, isNull);
      expect(vm.imagePreview!.name, 'cat.png');
      vm.dispose();
    });

    test('the preview is not recorded as a transfer', () async {
      // A row per image glanced at would bury the transfers the user actually started.
      final vm = await booted(imageTree());

      await vm.openImagePreview(img('cat.png'));

      expect(vm.transfers, isEmpty);
      vm.dispose();
    });

    test('a file that is not an image is not fetched at all', () async {
      final client = imageTree();
      final vm = await booted(client);

      await vm.openImagePreview(img('notes.txt'));

      expect(vm.imagePreview, isNull);
      vm.dispose();
    });

    test('a file past the ceiling is refused before the download', () async {
      // The point of a ceiling is to not spend the transfer.
      final client = imageTree();
      final vm = await booted(client);

      await vm.openImagePreview(img('huge.png', size: 128 * 1024 * 1024));

      expect(vm.imagePreview!.error, contains('Too large'));
      expect(vm.imagePreview!.bytes, isNull);
      vm.dispose();
    });

    test('a download failure is reported rather than left loading', () async {
      final client = imageTree()..failFor = {'/home/root/cat.png'};
      final vm = await booted(client);

      await vm.openImagePreview(img('cat.png'));

      expect(vm.imagePreview!.error, contains('cat.png'));
      expect(vm.imagePreview!.isLoading, isFalse);
      vm.dispose();
    });

    test('closing drops the bytes', () async {
      final vm = await booted(imageTree());
      await vm.openImagePreview(img('cat.png'));

      vm.closeImagePreview();

      expect(vm.imagePreview, isNull);
      vm.dispose();
    });

    test('a fetch that lands after closing does not reopen the overlay', () async {
      // Otherwise a slow image reappears over whatever the user moved on to.
      final vm = await booted(imageTree());

      final pending = vm.openImagePreview(img('cat.png'));
      vm.closeImagePreview();
      await pending;

      expect(vm.imagePreview, isNull);
      vm.dispose();
    });
  });

  group('batch download to a folder', () {
    /// A store that saves into a real temp directory, so the batch can be asserted on the files
    /// that actually landed rather than on calls it was asked to make.
    late Directory destination;

    setUp(() => destination = Directory.systemTemp.createTempSync('omniterm-dest-'));
    tearDown(() {
      if (destination.existsSync()) destination.deleteSync(recursive: true);
    });

    List<String> saved() =>
        destination.listSync().map((e) => e.path.split('/').last).toList()..sort();

    SftpFile file(String name, {int size = 10}) =>
        SftpFile(name: name, isDirectory: false, size: size, modDate: '2026-08-01');

    FakeFsClient tree() => FakeFsClient(
      tree: {
        '/home/root': [
          file('a.conf'),
          file('b.conf'),
          SftpFile(name: 'docs', isDirectory: true, size: 0, modDate: '2026-08-01'),
        ],
      },
    );

    test('every selected file lands in the folder, picked once', () async {
      final store = FakeDeviceFileStore(destination);
      final vm = await booted(tree());
      vm.toggleSelected('a.conf');
      vm.toggleSelected('b.conf');

      await vm.downloadSelectedToFolder(store);

      expect(store.folderPicks, 1, reason: 'one prompt, not one per file');
      expect(saved(), ['a.conf', 'b.conf']);
      expect(vm.status, contains('2 file(s)'));
      vm.dispose();
    });

    test('a selected directory is not downloaded', () async {
      // A directory has no bytes to hand to a save dialog, and walking into it would fetch a tree
      // the user selected a single row for.
      final store = FakeDeviceFileStore(destination);
      final vm = await booted(tree());
      vm.toggleSelected('docs');
      vm.toggleSelected('a.conf');

      await vm.downloadSelectedToFolder(store);

      expect(saved(), ['a.conf']);
      vm.dispose();
    });

    test('with only a directory selected there is nothing to do', () async {
      final store = FakeDeviceFileStore(destination);
      final vm = await booted(tree());
      vm.toggleSelected('docs');

      expect(vm.canBatchDownload, isFalse);
      await vm.downloadSelectedToFolder(store);

      expect(store.folderPicks, 0, reason: 'no prompt for a batch with no files in it');
      vm.dispose();
    });

    test('backing out of the folder picker moves nothing', () async {
      final store = FakeDeviceFileStore(destination, cancelFolder: true);
      final vm = await booted(tree());
      vm.toggleSelected('a.conf');

      await vm.downloadSelectedToFolder(store);

      expect(saved(), isEmpty);
      expect(vm.error, isNull, reason: 'a deliberate cancel is not a failure');
      expect(vm.selectedEntries, hasLength(1), reason: 'nothing was attempted');
      vm.dispose();
    });

    test('one file failing does not abandon the rest', () async {
      // The useful thing after a partial download is knowing which file to go back for, not losing
      // the ones that worked.
      final store = FakeDeviceFileStore(destination, failFor: {'a.conf'});
      final vm = await booted(tree());
      vm.toggleSelected('a.conf');
      vm.toggleSelected('b.conf');

      await vm.downloadSelectedToFolder(store);

      expect(saved(), ['b.conf']);
      expect(vm.error, contains('a.conf'));
      expect(vm.status, contains('1 of 2'));
      vm.dispose();
    });

    test('a file too large for the batch is skipped, and says where to go instead', () async {
      // The platform's save-into-a-folder API takes bytes, not a path, so a huge file would be held
      // in memory. The per-file download streams and has no such limit.
      final store = FakeDeviceFileStore(destination);
      final vm = await booted(
        FakeFsClient(
          tree: {
            '/home/root': [
              file('huge.img', size: SftpViewModel.batchDownloadByteCeiling + 1),
              file('a.conf'),
            ],
          },
        ),
      );
      vm.toggleSelected('huge.img');
      vm.toggleSelected('a.conf');

      await vm.downloadSelectedToFolder(store);

      expect(saved(), ['a.conf'], reason: 'the rest of the batch still runs');
      expect(vm.error, contains('Download to device'));
      vm.dispose();
    });

    test('the attempted files leave the selection and others stay', () async {
      final store = FakeDeviceFileStore(destination);
      final vm = await booted(tree());
      vm.toggleSelected('a.conf');
      vm.toggleSelected('docs');

      await vm.downloadSelectedToFolder(store);

      expect(
        vm.selectedEntries.map((e) => e.name),
        ['docs'],
        reason: 'a folder the user also selected is not silently dropped',
      );
      vm.dispose();
    });

    test('no staging copy is left behind on the device', () async {
      // A copy of a remote file left in the cache quietly widens access to it.
      final before = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('omniterm-dl-'))
          .length;
      final store = FakeDeviceFileStore(destination);
      final vm = await booted(tree());
      vm.toggleSelected('a.conf');
      vm.toggleSelected('b.conf');

      await vm.downloadSelectedToFolder(store);

      final after = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('omniterm-dl-'))
          .length;
      expect(after, before);
      vm.dispose();
    });

    test('the warning threshold counts files, not folders', () async {
      final vm = await booted(tree());
      vm.toggleSelected('docs');

      expect(vm.selectedDownloadBytes, 0);
      expect(vm.batchDownloadNeedsWarning, isFalse);
      vm.dispose();
    });
  });

  group('searching a network share', () {
    // A share has no shell, so `find` cannot be run on one. This port refused the search outright
    // when a share was open (`_browsedShare != null`) and hid the button with it, which left no way
    // at all to search a share. Compose walks it (`ui/AppViewModel.kt:8007`).
    NetworkShare mediaShare() => const NetworkShare(
      id: 5,
      name: 'media',
      protocol: 'SMB',
      address: 'nas.local',
      port: 445,
      sharePath: '/media',
      workgroup: '',
      username: 'sam',
      password: 'pw',
      anonymous: false,
      useHttps: false,
      notes: '',
      lastChecked: 0,
      lastStatus: 'online',
    );

    Future<SftpViewModel> openedShare(FakeFsClient client) async {
      await app.start();
      final vm = SftpViewModel(app, shareClientFor: (_) async => client);
      await vm.openShare(mediaShare());
      return vm;
    }

    test('the walk descends and finds a match several levels down', () async {
      final client = FakeFsClient(
        tree: {
          // SMB consumes the share name into the connection, so the walk starts at '/'.
          '/': [entry('films', dir: true), entry('readme.txt')],
          '/films': [entry('2026', dir: true)],
          '/films/2026': [entry('holiday.mkv'), entry('other.mkv')],
        },
      );
      final vm = await openedShare(client);

      await vm.searchShare('holiday');

      expect(vm.searchHits!.map((h) => h.path), ['/films/2026/holiday.mkv']);
      expect(vm.searchTruncated, isFalse);
      vm.dispose();
    });

    test('a directory that cannot be listed does not fail the whole search', () async {
      // Compose skips an unreadable directory and keeps going; a share with one permission-denied
      // folder must still return everything else.
      final client = FakeFsClient(
        tree: {
          '/': [entry('locked', dir: true), entry('open', dir: true)],
          '/open': [entry('target.txt')],
        },
      )..failFor.add('/locked');
      final vm = await openedShare(client);

      await vm.searchShare('target');

      expect(vm.searchHits!.map((h) => h.path), ['/open/target.txt']);
      expect(vm.error, isNull);
      vm.dispose();
    });

    test('the walk stops at the hit cap and says the answer is partial', () async {
      final client = FakeFsClient(
        tree: {
          '/': [for (var i = 0; i < shareSearchMaxHits + 10; i++) entry('clip$i.mkv')],
        },
      );
      final vm = await openedShare(client);

      await vm.searchShare('clip');

      expect(vm.searchHits, hasLength(shareSearchMaxHits));
      expect(vm.searchTruncated, isTrue, reason: 'a partial answer must not look complete');
      vm.dispose();
    });

    test('a host search is still what runs when no share is open', () async {
      final vm = await booted(homeTree());

      expect(vm.canSearchShare, isFalse, reason: 'no share is open, so the walk must not be used');
      vm.dispose();
    });
  });

  group('the share search matcher', () {
    test('a plain query matches anywhere in the name', () {
      final matches = shareSearchMatcher('hol');
      expect(matches('holiday.mkv'), isTrue);
      expect(matches('MY-HOLIDAY.mkv'), isTrue, reason: 'case-insensitive, as Compose is');
      expect(matches('other.mkv'), isFalse);
    });

    test('a query carrying a wildcard is taken as a pattern', () {
      final matches = shareSearchMatcher('*.mkv');
      expect(matches('holiday.mkv'), isTrue);
      expect(matches('holiday.mp4'), isFalse);

      final single = shareSearchMatcher('clip?.mkv');
      expect(single('clip1.mkv'), isTrue);
      expect(single('clip12.mkv'), isFalse);
    });

    test('regex metacharacters in a query are literal, not operators', () {
      // Without escaping, a file called `notes(1).txt` would be unfindable and a query of `a+b`
      // would silently mean something else.
      final matches = shareSearchMatcher('notes(1)*');
      expect(matches('notes(1).txt'), isTrue);
      expect(matches('notes1.txt'), isFalse);
    });
  });

  group('bookmarks across every endpoint', () {
    NetworkShare shareRow({
      String name = 'media',
      String protocol = 'SMB',
      String status = 'online',
    }) => NetworkShare(
      id: 0,
      name: name,
      protocol: protocol,
      address: 'nas.local',
      port: 445,
      sharePath: name,
      workgroup: '',
      username: 'sam',
      password: 'pw',
      anonymous: false,
      useHttps: false,
      notes: '',
      lastChecked: 0,
      lastStatus: status,
    );

    test('the list spans hosts and shares, each naming its endpoint', () async {
      final aId = await repo.insertServer(server(name: 'alpha'));
      final bId = await repo.insertServer(server(name: 'beta'));
      final shareId = await repo.insertNetworkShare(shareRow());
      await repo.insertSetting('sftp_bookmarks_$aId', '/srv/www|||/etc');
      await repo.insertSetting('sftp_bookmarks_$bId', '/opt/app');
      await repo.insertSetting('share_bookmarks_$shareId', '/photos');

      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();

      expect(
        vm.allBookmarks.map((b) => '${b.endpointName}:${b.path}'),
        containsAll(['alpha:/srv/www', 'alpha:/etc', 'beta:/opt/app', 'media (SMB):/photos']),
      );
      vm.dispose();
    });

    test('a host that never saved one contributes nothing', () async {
      // The five defaults are seeded in memory for the star column only. Writing them out would put
      // /root and /etc in this list for every host the user has never opened.
      await repo.insertServer(server(name: 'alpha'));
      final vm = await boot(client: homeTree());
      await vm.start();
      await vm.loadAllBookmarks();

      expect(vm.bookmarks, SftpViewModel.defaultBookmarks);
      expect(vm.allBookmarks, isEmpty);
      vm.dispose();
    });

    test('an offline host is listed but not openable', () async {
      final id = await repo.insertServer(server(name: 'alpha', status: 'offline'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');

      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();

      expect(vm.allBookmarks, hasLength(1));
      expect(vm.bookmarkIsAvailable(vm.allBookmarks.single), isFalse);
      vm.dispose();
    });

    test('a share is available until a probe says otherwise', () async {
      final okId = await repo.insertNetworkShare(shareRow(name: 'fresh', status: 'unknown'));
      final badId = await repo.insertNetworkShare(shareRow(name: 'dead', status: 'unreachable'));
      await repo.insertSetting('share_bookmarks_$okId', '/a');
      await repo.insertSetting('share_bookmarks_$badId', '/b');

      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();

      final fresh = vm.allBookmarks.firstWhere((b) => b.path == '/a');
      final dead = vm.allBookmarks.firstWhere((b) => b.path == '/b');
      expect(vm.bookmarkIsAvailable(fresh), isTrue);
      expect(vm.bookmarkIsAvailable(dead), isFalse);
      vm.dispose();
    });

    test('adding against a chosen host writes that host, not the browsed one', () async {
      // The defect this whole flow exists for: a bookmark filed against the wrong machine is
      // silently useless rather than visibly wrong.
      final browsed = await repo.insertServer(server(name: 'browsed'));
      final other = await repo.insertServer(server(name: 'other'));
      final vm = await boot(client: homeTree());
      app.selectedServerId = browsed;
      await vm.start();

      await vm.saveEndpointBookmark(serverId: other, path: '/srv/www');

      expect(await repo.getSetting('sftp_bookmarks_$other'), '/srv/www');
      expect(await repo.getSetting('sftp_bookmarks_$browsed'), isNull);
      vm.dispose();
    });

    test('a blank path becomes the root rather than an unopenable entry', () async {
      final id = await repo.insertServer(server(name: 'alpha'));
      final vm = await boot(client: homeTree());

      await vm.saveEndpointBookmark(serverId: id, path: '   ');

      expect(vm.allBookmarks.single.path, '/');
      vm.dispose();
    });

    test('saving a path the endpoint already has does not duplicate it', () async {
      final id = await repo.insertServer(server(name: 'alpha'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');
      final vm = await boot(client: homeTree());

      await vm.saveEndpointBookmark(serverId: id, path: '/etc');

      expect(await repo.getSetting('sftp_bookmarks_$id'), '/etc');
      expect(vm.allBookmarks, hasLength(1));
      vm.dispose();
    });

    test('editing across endpoints moves the bookmark in one operation', () async {
      // Otherwise the old entry survives on the old host and the user has to delete it by hand.
      final from = await repo.insertServer(server(name: 'from'));
      final to = await repo.insertServer(server(name: 'to'));
      await repo.insertSetting('sftp_bookmarks_$from', '/etc|||/opt');
      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();
      final original = vm.allBookmarks.firstWhere((b) => b.path == '/etc');

      await vm.saveEndpointBookmark(serverId: to, path: '/srv', replacing: original);

      expect(await repo.getSetting('sftp_bookmarks_$from'), '/opt');
      expect(await repo.getSetting('sftp_bookmarks_$to'), '/srv');
      vm.dispose();
    });

    test('cloning leaves the original in place', () async {
      final from = await repo.insertServer(server(name: 'from'));
      final to = await repo.insertServer(server(name: 'to'));
      await repo.insertSetting('sftp_bookmarks_$from', '/etc');
      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();

      // A clone is a save with no `replacing`, which is the whole difference from an edit.
      await vm.saveEndpointBookmark(serverId: to, path: '/etc');

      expect(await repo.getSetting('sftp_bookmarks_$from'), '/etc');
      expect(await repo.getSetting('sftp_bookmarks_$to'), '/etc');
      expect(vm.allBookmarks, hasLength(2));
      vm.dispose();
    });

    test('removing one leaves its endpoint\'s other bookmarks alone', () async {
      final id = await repo.insertServer(server(name: 'alpha'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc|||/opt|||/srv');
      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();

      await vm.removeEndpointBookmark(vm.allBookmarks.firstWhere((b) => b.path == '/opt'));

      expect(await repo.getSetting('sftp_bookmarks_$id'), '/etc|||/srv');
      vm.dispose();
    });

    test('removing one host\'s bookmark does not touch another host\'s', () async {
      final aId = await repo.insertServer(server(name: 'alpha'));
      final bId = await repo.insertServer(server(name: 'beta'));
      await repo.insertSetting('sftp_bookmarks_$aId', '/etc');
      await repo.insertSetting('sftp_bookmarks_$bId', '/etc');
      final vm = await boot(client: homeTree());
      await vm.loadAllBookmarks();

      await vm.removeEndpointBookmark(vm.allBookmarks.firstWhere((b) => b.serverId == aId));

      expect(await repo.getSetting('sftp_bookmarks_$aId'), '');
      expect(await repo.getSetting('sftp_bookmarks_$bId'), '/etc');
      vm.dispose();
    });

    test('a star set in the browser shows up in the cross-endpoint list', () async {
      final vm = await booted(homeTree());

      await vm.toggleBookmark('/srv/www');

      expect(vm.allBookmarks.map((b) => b.path), contains('/srv/www'));
      vm.dispose();
    });

    test('deleting from the tab clears the star in the browser', () async {
      final vm = await booted(homeTree());
      await vm.toggleBookmark('/srv/www');

      await vm.removeEndpointBookmark(vm.allBookmarks.firstWhere((b) => b.path == '/srv/www'));

      expect(vm.isBookmarked('/srv/www'), isFalse);
      vm.dispose();
    });

    test('opening one switches hosts, tab and directory', () async {
      final aId = await repo.insertServer(server(name: 'alpha'));
      final bId = await repo.insertServer(server(name: 'beta'));
      await repo.insertSetting('sftp_bookmarks_$bId', '/srv/www');
      final client = homeTree()..tree['/srv/www'] = [entry('index.html')];

      final vm = await boot(client: client);
      app.selectedServerId = aId;
      await vm.start();
      await vm.loadAllBookmarks();

      await vm.openEndpointBookmark(vm.allBookmarks.single);

      expect(app.selectedServerId, bId);
      expect(vm.activeTab, SftpTab.files);
      expect(vm.path, '/srv/www');
      vm.dispose();
    });

    test('opening an offline host does nothing at all', () async {
      // Re-checked in the view model as well as greyed in the UI: the list is a snapshot, and a host
      // that dropped since the last paint must not be dialled by a stale tap.
      final id = await repo.insertServer(server(name: 'gone', status: 'offline'));
      await repo.insertSetting('sftp_bookmarks_$id', '/srv/www');
      final client = homeTree();
      final vm = await boot(client: client);
      await vm.loadAllBookmarks();
      final before = List<String>.from(client.listed);

      await vm.openEndpointBookmark(vm.allBookmarks.single);

      expect(vm.activeTab, isNot(SftpTab.files));
      expect(client.listed, before);
      vm.dispose();
    });

    test('opening a bookmark on the browsed host still lands on the path', () async {
      final id = await repo.insertServer(server(name: 'alpha'));
      await repo.insertSetting('sftp_bookmarks_$id', '/srv/www');
      final client = homeTree()..tree['/srv/www'] = [entry('index.html')];
      final vm = await boot(client: client);
      await vm.start();
      await vm.loadAllBookmarks();

      await vm.openEndpointBookmark(vm.allBookmarks.single);

      expect(vm.path, '/srv/www');
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

    test('with sudo off the search is an ordinary command', () async {
      final ssh = FakeShell('');
      final vm = await booted(homeTree(), shell: ssh);

      await vm.searchHost('x');

      expect(ssh.commands.single, startsWith('find '));
      expect(ssh.stdins.single, isNull);
      vm.dispose();
    });

    test('with sudo on the search runs as root', () async {
      // The defect: every other exec on this screen elevated and this one did not, so searching a
      // tree the user turned sudo on to reach came back empty.
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final ssh = FakeShell('f\t/etc/shadow\n');
      final vm = await boot(client: homeTree(), shell: ssh);
      await Future<void>.delayed(Duration.zero);
      await vm.start();
      vm.sudoMode = true;

      await vm.searchHost('shadow');

      expect(ssh.commands.single, startsWith('sudo -S'));
      expect(ssh.commands.single, contains('find '));
      expect(vm.searchHits, hasLength(1));
      vm.dispose();
    });

    test('the sudo password goes over stdin, never into the command line', () async {
      // A command line is visible in `ps`, auditd execve records and sshd debug logs — all readable
      // by other users on the host.
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final ssh = FakeShell('');
      final vm = await boot(client: homeTree(), shell: ssh);
      await Future<void>.delayed(Duration.zero);
      await vm.start();
      vm.sudoMode = true;

      await vm.searchHost('x');

      expect(ssh.commands.single, isNot(contains('hunter2')));
      expect(ssh.stdins.single, 'hunter2\n');
      vm.dispose();
    });

    test('a refused sudo is reported, not returned as "nothing found"', () async {
      // `find` sends its permission errors to /dev/null, so without this check a search of a tree
      // the login cannot read reports an empty result — a wrong answer that looks like a right one.
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final ssh = FakeShell('sudo: 3 incorrect password attempts\n');
      final vm = await boot(client: homeTree(), shell: ssh);
      await Future<void>.delayed(Duration.zero);
      await vm.start();
      vm.sudoMode = true;

      await vm.searchHost('x');

      expect(vm.searchHits, isNull);
      expect(vm.error, contains('incorrect password'));
      vm.dispose();
    });

    test('a hit whose name reads like an error is still a hit', () async {
      // Only the first line is inspected, so a file genuinely called "no such file" does not
      // suppress the results it appears in.
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      final ssh = FakeShell('f\t/srv/no such file.txt\n');
      final vm = await boot(client: homeTree(), shell: ssh);
      await Future<void>.delayed(Duration.zero);
      await vm.start();
      vm.sudoMode = true;

      await vm.searchHost('such');

      expect(vm.error, isNull);
      expect(vm.searchHits!.single.path, '/srv/no such file.txt');
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

  /// Destination conflicts, ported from `sftpBeginPaste` in `ui/AppViewModel.kt`.
  ///
  /// Pasting used to call `uniqueName` on every clash, so a file could never be replaced and the
  /// user was never told one already existed.
  group('paste conflicts', () {
    /// A scan result for [sources], in the real index-keyed wire format.
    String scanOutput(List<(int, String)> rows) => [
      for (final (index, verdict) in rows) '$index\t$verdict\t10\t20\t100\t200',
      conflictScanOk,
    ].join('\n');

    /// A tree where /home/root already holds `notes.txt`.
    FakeFsClient collidingTree() => FakeFsClient(
      tree: {
        '/home/root': [entry('notes.txt', size: 10), entry('other.txt', size: 3)],
        '/home/root/docs': [entry('notes.txt', size: 20)],
      },
    );

    /// Stages `docs/notes.txt` and navigates back to /home/root, where the name clashes.
    Future<SftpViewModel> stagedClash(
      FakeFsClient client, {
      SshTransport? shell,
      bool move = false,
    }) async {
      final vm = await booted(client, shell: shell);
      await vm.openPath('/home/root/docs');
      vm.toggleSelected('notes.txt');
      vm.stageSelected(move: move);
      await vm.openPath('/home/root');
      return vm;
    }

    /// Pasting a folder into its own subtree is unbounded.
    ///
    /// `_copyRemoteEntry` creates the destination and then lists the source, which now contains what
    /// it just created, and recurses into it forever — filling the remote disk and hanging the
    /// transfer. A same-endpoint *move* is safe because the server refuses the rename, but a copy is
    /// the app's own recursion and nothing stopped it.
    group('pasting a folder into itself', () {
      FakeFsClient nestedTree() => FakeFsClient(
        tree: {
          '/home/root': [entry('docs', dir: true)],
          '/home/root/docs': [entry('sub', dir: true)],
          '/home/root/docs/sub': [],
        },
      );

      Future<SftpViewModel> stageDocsThenEnter(
        FakeFsClient client,
        String destination, {
        bool move = false,
      }) async {
        final vm = await booted(client);
        vm.toggleSelected('docs');
        vm.stageSelected(move: move);
        await vm.openPath(destination);
        return vm;
      }

      test('a direct child destination is refused', () async {
        final client = nestedTree();
        final vm = await stageDocsThenEnter(client, '/home/root/docs');

        await vm.beginPaste(recurseFolders: true);

        expect(vm.error, contains('into itself'));
        expect(client.created, isEmpty, reason: 'nothing may be written before the refusal');
        vm.dispose();
      });

      test('a deeper descendant is refused too', () async {
        final client = nestedTree();
        final vm = await stageDocsThenEnter(client, '/home/root/docs/sub');

        await vm.beginPaste(recurseFolders: true);

        expect(vm.error, contains('into itself'));
        expect(client.created, isEmpty);
        vm.dispose();
      });

      test('pasteClipboard refuses it directly, not only through beginPaste', () async {
        // The recursion lives here, so the guard cannot be only on the path that usually calls it.
        final client = nestedTree();
        final vm = await stageDocsThenEnter(client, '/home/root/docs/sub');

        await vm.pasteClipboard(recurseFolders: true);

        expect(vm.error, contains('into itself'));
        expect(client.created, isEmpty);
        vm.dispose();
      });

      test('a sibling whose name is a prefix is still allowed', () async {
        // `/srv/www-old`.startsWith(`/srv/www`) is true but it is a sibling, not a child. A string
        // prefix test would refuse a perfectly ordinary paste.
        final client = FakeFsClient(
          tree: {
            '/home/root': [entry('www', dir: true), entry('www-old', dir: true)],
            '/home/root/www': [],
            '/home/root/www-old': [],
          },
        );
        final vm = await booted(client);
        vm.toggleSelected('www');
        vm.stageSelected(move: false);
        await vm.openPath('/home/root/www-old');

        await vm.beginPaste(recurseFolders: true);

        expect(vm.error, isNull, reason: 'a sibling is not a subtree');
        vm.dispose();
      });

      test('a file with the same name as the folder is not refused', () async {
        // Only directories can contain the destination; a file never can.
        final client = FakeFsClient(
          tree: {
            '/home/root': [entry('docs', size: 10)],
            '/home/root/elsewhere': [],
          },
        );
        final vm = await booted(client);
        vm.toggleSelected('docs');
        vm.stageSelected(move: false);
        await vm.openPath('/home/root/elsewhere');

        await vm.beginPaste(recurseFolders: false);

        expect(vm.error, isNull);
        vm.dispose();
      });
    });

    test('a name that does not clash pastes without asking', () async {
      final client = collidingTree();
      final vm = await booted(client);
      await vm.openPath('/home/root/docs');
      vm.toggleSelected('notes.txt');
      vm.stageSelected(move: false);
      // Paste back into docs itself is a clash, so go somewhere the name is free.
      client.tree['/tmp'] = [];
      await vm.openPath('/tmp');

      await vm.beginPaste(recurseFolders: false);
      expect(vm.pasteConflicts, isEmpty);
      expect(vm.status, contains('Copied 1 item'));
      vm.dispose();
    });

    test('a clash is reported with the verdict the host measured', () async {
      final shell = FakeShell(scanOutput([(0, 'DIFFERENT')]));
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);

      await vm.beginPaste(recurseFolders: false);

      expect(vm.pasteConflicts, hasLength(1));
      expect(vm.pasteConflicts.single.name, 'notes.txt');
      expect(vm.pasteConflicts.single.verdict, ConflictVerdict.different);
      expect(
        vm.pasteConflicts.single.action,
        ConflictAction.keepBoth,
        reason: 'only a proven-identical pair may default to overwrite',
      );
      expect(vm.conflictsUnverified, isFalse);
      // Nothing may move before the user answers.
      expect(client.deleted, isEmpty);
      expect(client.renamed, isEmpty);
      expect(client.written, isEmpty);
      vm.dispose();
    });

    test('a truncated scan cancels the paste rather than overwriting', () async {
      // Without the sentinel the scan may have died half way; reading that as "no conflicts" would
      // turn a failed check into a silent overwrite.
      final shell = FakeShell('0\tIDENTICAL\t1\t1\t1\t1');
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);

      await vm.beginPaste(recurseFolders: false);

      expect(vm.pasteConflicts, isEmpty);
      expect(vm.error, contains('conflict scan'));
      expect(client.renamed, isEmpty);
      vm.dispose();
    });

    test('without a shell the clash is still raised, as unverified', () async {
      // A share has no shell at all. Saying nothing and renaming silently would be the old bug.
      final vm = await stagedClash(collidingTree());

      await vm.beginPaste(recurseFolders: false);

      expect(vm.pasteConflicts, hasLength(1));
      expect(vm.pasteConflicts.single.verdict, ConflictVerdict.unknown);
      expect(
        vm.conflictsUnverified,
        isTrue,
        reason: 'the UI must say the pair could not be compared, not imply a match',
      );
      vm.dispose();
    });

    test('overwrite deletes the existing entry so the name is reused', () async {
      final shell = FakeShell(scanOutput([(0, 'DIFFERENT')]));
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);
      await vm.beginPaste(recurseFolders: false);

      vm.setPasteConflictAction('notes.txt', ConflictAction.overwrite);
      await vm.confirmPasteConflicts();

      expect(client.deleted, contains('/home/root/notes.txt'));
      expect(vm.status, contains('Copied 1 item'));
      vm.dispose();
    });

    test('skip transfers nothing and says so', () async {
      final shell = FakeShell(scanOutput([(0, 'DIFFERENT')]));
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);
      await vm.beginPaste(recurseFolders: false);

      vm.setPasteConflictAction('notes.txt', ConflictAction.skip);
      await vm.confirmPasteConflicts();

      expect(client.deleted, isEmpty);
      expect(vm.status, contains('skipped 1'));
      vm.dispose();
    });

    test('keep both renames instead of replacing', () async {
      final shell = FakeShell(scanOutput([(0, 'IDENTICAL')]));
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);
      await vm.beginPaste(recurseFolders: false);

      vm.setPasteConflictAction('notes.txt', ConflictAction.keepBoth);
      await vm.confirmPasteConflicts();

      expect(client.deleted, isEmpty, reason: 'keeping both destroys nothing');
      expect(vm.status, contains('Copied 1 item'));
      vm.dispose();
    });

    test('apply-to-all sets every row at once', () async {
      final shell = FakeShell(scanOutput([(0, 'DIFFERENT')]));
      final vm = await stagedClash(collidingTree(), shell: shell);
      await vm.beginPaste(recurseFolders: false);

      vm.setAllPasteConflictActions(ConflictAction.skip);
      expect(vm.pasteConflicts.every((c) => c.action == ConflictAction.skip), isTrue);
      vm.dispose();
    });

    test('cancelling clears the prompt and transfers nothing', () async {
      final shell = FakeShell(scanOutput([(0, 'DIFFERENT')]));
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);
      await vm.beginPaste(recurseFolders: false);

      vm.cancelPasteConflicts();

      expect(vm.pasteConflicts, isEmpty);
      expect(vm.conflictsUnverified, isFalse);
      expect(client.deleted, isEmpty);
      expect(client.renamed, isEmpty);
      vm.dispose();
    });

    test('pasting into the source folder keeps both rather than overwriting', () async {
      // An IDENTICAL default of overwrite would delete the file and then copy it onto itself.
      final shell = FakeShell(scanOutput([(0, 'IDENTICAL')]));
      final client = collidingTree();
      final vm = await booted(client, shell: shell);
      await vm.openPath('/home/root/docs');
      vm.toggleSelected('notes.txt');
      vm.stageSelected(move: false);

      await vm.beginPaste(recurseFolders: false);

      expect(vm.pasteConflicts.single.action, ConflictAction.keepBoth);
      vm.dispose();
    });

    test('restaging while the scan is pending abandons the stale resolution', () async {
      final shell = FakeShell(scanOutput([(0, 'DIFFERENT')]));
      final client = collidingTree();
      final vm = await stagedClash(client, shell: shell);
      await vm.beginPaste(recurseFolders: false);

      // The user restages a different selection before answering.
      vm.toggleSelected('other.txt');
      vm.stageSelected(move: false);
      await vm.confirmPasteConflicts();

      expect(vm.error, contains('changed'));
      expect(client.deleted, isEmpty, reason: 'the old answer must not apply to a new selection');
      vm.dispose();
    });
  });

  /// The editor's binary warning, wired in `readForEditing`.
  ///
  /// The domain check is useless unless something calls it: `looksBinary` sat in `file_edit.dart`,
  /// fully written and tested, and no route into the editor ever consulted it.
  group('editor binary warning', () {
    FakeFsClient withFile(String name, String contents) {
      final client = FakeFsClient(
        tree: {
          '/home/root': [entry(name, size: contents.length)],
        },
      );
      client.files['/home/root/$name'] = contents;
      return client;
    }

    test('a text file opens with no warning', () async {
      final client = withFile('notes.txt', 'hello\nworld\n');
      final vm = await booted(client);

      final content = await vm.readForEditing(entry('notes.txt', size: 12));

      expect(content, 'hello\nworld\n');
      expect(vm.editorBinaryWarning, isNull);
      vm.dispose();
    });

    test('a file with NUL bytes warns that saving would corrupt it', () async {
      final client = withFile('app.bin', 'MZ\u0000\u0000program');
      final vm = await booted(client);

      await vm.readForEditing(entry('app.bin', size: 20));

      expect(vm.editorBinaryWarning, isNotNull);
      expect(vm.editorBinaryWarning, contains('corrupt'));
      vm.dispose();
    });

    test('a lossily decoded file warns about the replacements', () async {
      // The SFTP client decodes with allowMalformed, so invalid bytes are already U+FFFD here.
      final client = withFile('data.dat', 'caf\uFFFD value');
      final vm = await booted(client);

      await vm.readForEditing(entry('data.dat', size: 16));

      expect(vm.editorBinaryWarning, contains('not valid UTF-8'));
      vm.dispose();
    });

    test('the warning does not persist onto the next file opened', () async {
      final client = withFile('app.bin', 'MZ\u0000program');
      client.files['/home/root/notes.txt'] = 'plain text';
      client.tree['/home/root'] = [entry('app.bin', size: 15), entry('notes.txt', size: 10)];
      final vm = await booted(client);

      await vm.readForEditing(entry('app.bin', size: 15));
      expect(vm.editorBinaryWarning, isNotNull);

      await vm.readForEditing(entry('notes.txt', size: 10));
      expect(
        vm.editorBinaryWarning,
        isNull,
        reason: 'a stale warning would accuse an innocent file',
      );
      vm.dispose();
    });
  });

  /// The SFTP sort order, persisted under the same `sftp_sort` key Kotlin uses
  /// (`AppViewModel.kt:1410` writes it, `:2166` reads it back).
  ///
  /// Flutter held it in memory only, so a browser that had been asked to show newest-first was back
  /// to Name A-Z on the next launch — a setting the user can change that does not survive.
  group('sort order persistence', () {
    test('choosing a sort writes it under the Kotlin key', () async {
      final vm = await booted(homeTree());

      vm.sortOption = SftpSortOption.modifiedDesc;
      await Future<void>.delayed(Duration.zero);

      expect(await repo.getSetting('sftp_sort'), 'modifiedDesc');
      vm.dispose();
    });

    test('a stored order is in force before the first listing', () async {
      await repo.insertSetting('sftp_sort', 'sizeDesc');
      final vm = await booted(homeTree());

      expect(vm.sortOption, SftpSortOption.sizeDesc);
      vm.dispose();
    });

    test('the share browser\'s Android sort is adopted when there is no files sort', () async {
      // Defect 78. Kotlin keeps *two* sorts: `sftp_sort` for the Files tab and `share_sort` for the
      // share browser (`AppViewModel.kt:7860`). This port has one, because a share takes over the
      // Files tab — so a user who only ever changed the sort while browsing a share had their
      // choice silently dropped on upgrade.
      await repo.insertSetting('share_sort', 'ModifiedDesc');
      final vm = await booted(homeTree());

      expect(vm.sortOption, SftpSortOption.modifiedDesc);
      vm.dispose();
    });

    test('the files sort wins when both were set', () async {
      // Not a merge: `sftp_sort` is this app's own key and the one it writes, so it has to win or a
      // value the user set *here* would be overridden by one carried in from the old app.
      await repo.insertSetting('sftp_sort', 'sizeDesc');
      await repo.insertSetting('share_sort', 'ModifiedDesc');
      final vm = await booted(homeTree());

      expect(vm.sortOption, SftpSortOption.sizeDesc);
      vm.dispose();
    });

    test("a value written by the Android app is honoured, not reset", () async {
      // Kotlin's enum spells it `SizeDesc`; Dart's `.name` is `sizeDesc`. An exact comparison would
      // silently put every upgrading user back on Name A-Z.
      await repo.insertSetting('sftp_sort', 'SizeDesc');
      final vm = await booted(homeTree());

      expect(vm.sortOption, SftpSortOption.sizeDesc);
      vm.dispose();
    });

    test('an unrecognised stored value falls back rather than throwing', () async {
      await repo.insertSetting('sftp_sort', 'byVibes');
      final vm = await booted(homeTree());

      expect(vm.sortOption, SftpSortOption.nameAsc);
      vm.dispose();
    });

    test('re-selecting the current order writes nothing new', () async {
      final vm = await booted(homeTree());
      vm.sortOption = SftpSortOption.nameDesc;
      await Future<void>.delayed(Duration.zero);

      vm.sortOption = SftpSortOption.nameDesc;
      await Future<void>.delayed(Duration.zero);

      expect(await repo.getSetting('sftp_sort'), 'nameDesc');
      vm.dispose();
    });
  });

  /// The recursive-folder-copy opt-in, persisted under Kotlin's `cross_paste_recurse` key
  /// (`AppViewModel.kt:1228` writes it, `:2172` reads it back).
  ///
  /// Kotlin treats it as a standing preference — a checkbox in the clipboard bar — so a user who
  /// always wants folder contents says so once. Flutter asked with a modal on every single paste.
  group('recursive copy opt-in', () {
    test('defaults to off, so folders are never carried unasked', () async {
      final vm = await booted(homeTree());

      expect(vm.recurseFolders, isFalse);
      vm.dispose();
    });

    test('opting in is written under the Kotlin key', () async {
      final vm = await booted(homeTree());

      await vm.setRecurseFolders(true);

      expect(await repo.getSetting('cross_paste_recurse'), 'true');
      expect(vm.recurseFolders, isTrue);
      vm.dispose();
    });

    test('the opt-in survives a restart', () async {
      await repo.insertSetting('cross_paste_recurse', 'true');
      final vm = await booted(homeTree());

      expect(vm.recurseFolders, isTrue);
      vm.dispose();
    });

    test('an absent or malformed value reads as off', () async {
      // Anything that is not exactly "true" must not silently enable a slower, heavier transfer.
      await repo.insertSetting('cross_paste_recurse', 'yes please');
      final vm = await booted(homeTree());

      expect(vm.recurseFolders, isFalse);
      vm.dispose();
    });

    test('opting back out is persisted too', () async {
      await repo.insertSetting('cross_paste_recurse', 'true');
      final vm = await booted(homeTree());

      await vm.setRecurseFolders(false);

      expect(await repo.getSetting('cross_paste_recurse'), 'false');
      vm.dispose();
    });

    test('a folder paste with the opt-in stored is not refused', () async {
      // The guard that used to block this is what the prompt existed to satisfy.
      await repo.insertSetting('cross_paste_recurse', 'true');
      final client = FakeFsClient(
        tree: {
          '/home/root': [entry('docs', dir: true)],
          '/home/root/docs': [],
          '/tmp': [],
        },
      );
      final vm = await booted(client);
      vm.toggleSelected('docs');
      vm.stageSelected(move: false);
      await vm.openPath('/tmp');

      await vm.beginPaste(recurseFolders: vm.recurseFolders);

      expect(vm.error, isNull);
      vm.dispose();
    });
  });

  /// The aggregate exposed to the Transfers tab, ported from `transferAggregate`
  /// (`ui/AppViewModel.kt:9874`).
  group('transfer aggregate', () {
    test('nothing running means no bar', () async {
      final vm = await booted(homeTree());
      expect(vm.transferAggregate(), isNull);
      vm.dispose();
    });

    test('only running transfers count', () async {
      // A finished row must not keep inflating the batch it already left.
      final vm = await booted(homeTree());
      final done =
          SftpTransfer(id: 'a', name: 'a', direction: TransferDirection.download, totalBytes: 100)
            ..copiedBytes = 100
            ..status = TransferStatus.done;
      final live = SftpTransfer(
        id: 'b',
        name: 'b',
        direction: TransferDirection.download,
        totalBytes: 200,
      )..copiedBytes = 50;
      vm.debugAddTransfers([done, live]);

      final agg = vm.transferAggregate()!;
      expect(agg.activeFiles, 1);
      expect(agg.totalBytes, 200);
      expect(agg.bytesTransferred, 50);
      vm.dispose();
    });

    test('speed is derived from elapsed time, not invented', () async {
      final vm = await booted(homeTree());
      final started = DateTime(2026, 1, 1, 12);
      final live = SftpTransfer(
        id: 'b',
        name: 'b',
        direction: TransferDirection.download,
        totalBytes: 2048 * 1024,
        startedAt: started,
      )..copiedBytes = 1024 * 1024;
      vm.debugAddTransfers([live]);

      // One megabyte in two seconds is 512 KB/s.
      final agg = vm.transferAggregate(now: started.add(const Duration(seconds: 2)))!;
      expect(agg.speedKbps, closeTo(512, 1));
      expect(agg.etaSeconds, closeTo(2, 1));
      vm.dispose();
    });

    test('a transfer that has moved nothing reports no speed', () async {
      // Rather than dividing by an elapsed time and claiming a rate off one byte.
      final vm = await booted(homeTree());
      final started = DateTime(2026, 1, 1, 12);
      vm.debugAddTransfers([
        SftpTransfer(
          id: 'b',
          name: 'b',
          direction: TransferDirection.download,
          totalBytes: 100,
          startedAt: started,
        ),
      ]);

      final agg = vm.transferAggregate(now: started.add(const Duration(seconds: 5)))!;
      expect(agg.speedKbps, 0);
      expect(agg.etaSeconds, -1);
      vm.dispose();
    });
  });

  /// Uploading from the device, ported from Kotlin's upload action.
  ///
  /// `SftpViewModel.upload` existed with no caller anywhere in the UI, so there was no way to put a
  /// file onto a host from the SFTP screen at all.
  group('upload from device', () {
    late Directory scratch;

    setUp(() => scratch = Directory.systemTemp.createTempSync('omniterm-up-'));
    tearDown(() => scratch.deleteSync(recursive: true));

    File localFile(String name, String contents) =>
        File('${scratch.path}/$name')..writeAsStringSync(contents);

    test('the file lands under its own name', () async {
      final client = FakeFsClient(tree: {'/home/root': []});
      final vm = await booted(client);
      final source = localFile('notes.txt', 'hello');

      await vm.uploadFromDevice(source.path);

      expect(client.uploaded, contains('/home/root/notes.txt'));
      vm.dispose();
    });

    test('a clashing name is suffixed, never overwritten', () async {
      // An upload that silently replaces a file the user did not mean to touch is unrecoverable.
      final client = FakeFsClient(
        tree: {
          '/home/root': [entry('notes.txt', size: 10)],
        },
      );
      final vm = await booted(client);
      final source = localFile('notes.txt', 'hello');

      await vm.uploadFromDevice(source.path);

      expect(client.uploaded.single, isNot('/home/root/notes.txt'));
      expect(client.uploaded.single, contains('notes'));
      vm.dispose();
    });

    test('a transfer row is recorded', () async {
      final client = FakeFsClient(tree: {'/home/root': []});
      final vm = await booted(client);

      await vm.uploadFromDevice(localFile('a.txt', 'x').path);

      expect(vm.transfers, hasLength(1));
      expect(vm.transfers.single.direction, TransferDirection.upload);
      expect(vm.transfers.single.status, TransferStatus.done);
      vm.dispose();
    });

    test('a file that cannot be read reports why and uploads nothing', () async {
      final client = FakeFsClient(tree: {'/home/root': []});
      final vm = await booted(client);

      await vm.uploadFromDevice('${scratch.path}/not-here.txt');

      expect(vm.error, contains('Could not read'));
      expect(client.uploaded, isEmpty);
      vm.dispose();
    });

    test('sizeOfLocalFile reports 0 rather than throwing on a missing file', () async {
      // The size only decides whether to warn; failing to stat must not block the upload that would
      // report the real problem.
      final vm = await booted(FakeFsClient(tree: {'/home/root': []}));

      expect(await vm.sizeOfLocalFile('${scratch.path}/absent'), 0);
      expect(await vm.sizeOfLocalFile(localFile('b.txt', 'abcde').path), 5);
      vm.dispose();
    });
  });
}
