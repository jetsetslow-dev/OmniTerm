import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/sftp/sftp_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shares_view_model.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';
import 'package:provider/provider.dart';

import 'sftp_view_model_test.dart' show FakeFsClient;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late SftpViewModel vm;

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

  SftpFile entry(String name, {bool dir = false, int size = 10}) =>
      SftpFile(name: name, isDirectory: dir, size: size, modDate: '2026-08-01');

  FakeFsClient homeTree() => FakeFsClient(
    tree: {
      '/home/root': [entry('docs', dir: true), entry('notes.txt', size: 120), entry('.hidden')],
      '/home/root/docs': [entry('report.pdf', size: 900)],
    },
  );

  Future<void> pump(WidgetTester tester, {FakeFsClient? client, SharesViewModel? shares}) async {
    await app.start();
    vm = SftpViewModel(app, fsClientFor: (_) async => client);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<SftpViewModel>.value(value: vm),
          // Built by the caller so the one test that needs it can dispose it inside the test body
          // (convention 5): this view model subscribes to a drift `watch` stream, and cancelling
          // that at teardown leaves zero-duration timers queued past the end-of-test check.
          if (shares != null) ChangeNotifierProvider<SharesViewModel>.value(value: shares),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: SftpScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> goToFiles(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('sftp.tab.files')));
    await tester.pumpAndSettle();
  }

  testWidgets('all four tabs are present', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());

    for (final tab in SftpTab.values) {
      expect(find.byKey(ValueKey('sftp.tab.${tab.name}')), findsOneWidget);
    }
    vm.dispose();
  });

  testWidgets('the browser tab is disabled with no online host', (tester) async {
    // Bookmarks, Shares and Transfers still work — only browsing needs a reachable host.
    await repo.insertServer(server(name: 'nas', status: 'offline'));
    await pump(tester, client: homeTree());

    final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('sftp.tab.files')));
    expect(chip.onSelected, isNull);

    await tester.tap(find.byKey(const ValueKey('sftp.tab.transfers')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sftp.transfers.empty')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('the browser lists the home directory with breadcrumbs', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);

    expect(find.byKey(const ValueKey('sftp.list')), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp.crumb./home/root')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('dotfiles are hidden until the toggle is used', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);

    expect(find.text('.hidden'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sftp.toggleHidden')));
    await tester.pumpAndSettle();
    expect(find.text('.hidden'), findsOneWidget);
    vm.dispose();
  });

  testWidgets('tapping a folder navigates into it', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);

    await tester.tap(find.byKey(const ValueKey('sftp.entry.docs')));
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp.crumb./home/root/docs')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sftp.up')));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    vm.dispose();
  });

  testWidgets('a folder shows no size, a file does', (tester) async {
    // A directory's reported size is its inode's, not its contents'.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);

    expect(find.text('120 B · 2026-08-01'), findsOneWidget);
    expect(find.text('2026-08-01'), findsOneWidget, reason: 'the folder row shows only the date');
    vm.dispose();
  });

  testWidgets('search distinguishes "no match" from "empty folder"', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);

    await tester.enterText(find.byKey(const ValueKey('sftp.search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches your search'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('sftp.search')), '');
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    vm.dispose();
  });

  group('destructive actions', () {
    testWidgets('deleting asks first and warns about folder contents', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree();
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.docs.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // Singular: one folder is "inside it", not "inside them". Spotted on a device.
      expect(find.textContaining('1 folder and everything inside it.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sftp.delete.cancel')));
      await tester.pumpAndSettle();
      expect(client.deleted, isEmpty, reason: 'cancelling must delete nothing');

      await tester.tap(find.byKey(const ValueKey('sftp.entry.docs.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sftp.delete.confirm')));
      await tester.pumpAndSettle();
      expect(client.deleted, ['/home/root/docs']);
      vm.dispose();
    });

    testWidgets('a file delete does not mention folder contents', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('everything inside'), findsNothing);
      expect(find.textContaining('cannot be recovered'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sftp.delete.cancel')));
      await tester.pumpAndSettle();
      vm.dispose();
    });
  });

  group('creating and renaming', () {
    testWidgets('a new folder is created', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree();
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.newFolder')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.newFolder.name')), 'archive');
      await tester.tap(find.byKey(const ValueKey('sftp.newFolder.confirm')));
      await tester.pumpAndSettle();

      expect(client.created, ['/home/root/archive']);
      vm.dispose();
    });

    testWidgets('an invalid name is reported and never sent', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree();
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.newFolder')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.newFolder.name')), '..');
      await tester.tap(find.byKey(const ValueKey('sftp.newFolder.confirm')));
      await tester.pumpAndSettle();

      expect(client.created, isEmpty);
      expect(find.textContaining('cannot be used'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('renaming an entry sends the new path', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree();
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.rename.name')), 'todo.txt');
      await tester.tap(find.byKey(const ValueKey('sftp.rename.confirm')));
      await tester.pumpAndSettle();

      expect(client.renamed, [('/home/root/notes.txt', '/home/root/todo.txt')]);
      vm.dispose();
    });
  });

  group('bookmarks', () {
    testWidgets('the defaults are listed and open the browser', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree()..tree['/etc'] = [entry('hosts')];
      await pump(tester, client: client);

      expect(find.byKey(const ValueKey('sftp.bookmark./etc')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sftp.bookmark./etc')));
      await tester.pumpAndSettle();

      expect(find.text('hosts'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('the current folder can be bookmarked from the browser', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.bookmarkToggle')));
      await tester.pumpAndSettle();
      expect(vm.isBookmarked('/home/root'), isTrue);

      await tester.tap(find.byKey(const ValueKey('sftp.tab.bookmarks')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sftp.bookmark./home/root')), findsOneWidget);
      vm.dispose();
    });
  });

  testWidgets('a listing failure is shown and the rows are cleared', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final client = homeTree()..failFor = {'/home/root/docs'};
    await pump(tester, client: client);
    await goToFiles(tester);

    await tester.tap(find.byKey(const ValueKey('sftp.entry.docs')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sftp.error')), findsOneWidget);
    expect(find.textContaining('permission denied'), findsOneWidget);
    expect(
      find.text('notes.txt'),
      findsNothing,
      reason: 'the previous folder rows must not sit under a path that failed to open',
    );
    vm.dispose();
  });

  testWidgets('the shares tab is the real one', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final shares = SharesViewModel(app);
    await pump(tester, client: homeTree(), shares: shares);

    await tester.tap(find.byKey(const ValueKey('sftp.tab.shares')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shares.add')), findsOneWidget);
    expect(find.byKey(const ValueKey('shares.empty')), findsOneWidget);
    vm.dispose();
    shares.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  });
}
