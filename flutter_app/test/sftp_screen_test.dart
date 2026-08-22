import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/sftp/sftp_screen.dart';
import 'package:omniterm/ui/theme/colors.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shares_view_model.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';
import 'package:provider/provider.dart';

import 'sftp_view_model_test.dart' show FakeFsClient;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late SftpViewModel vm;
  late AppLockController lock;
  late NavigationController nav;

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

  SftpFile entry(String name, {bool dir = false, int size = 10}) =>
      SftpFile(name: name, isDirectory: dir, size: size, modDate: '2026-08-01');

  FakeFsClient homeTree() => FakeFsClient(
    tree: {
      '/home/root': [entry('docs', dir: true), entry('notes.txt', size: 120), entry('.hidden')],
      '/home/root/docs': [entry('report.pdf', size: 900)],
    },
  );

  Future<void> pump(
    WidgetTester tester, {
    FakeFsClient? client,
    SharesViewModel? shares,
    SshTransport? transport,
    Size size = const Size(800, 600),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.start();
    vm = SftpViewModel(app, fsClientFor: (_) async => client, transport: transport);
    // Sudo mode re-authenticates before switching on, so the lock is in scope as it is in the app.
    nav = NavigationController();
    lock = AppLockController(repo);
    await lock.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<SftpViewModel>.value(value: vm),
          // Built by the caller so the one test that needs it can dispose it inside the test body
          // (convention 5): this view model subscribes to a drift `watch` stream, and cancelling
          // that at teardown leaves zero-duration timers queued past the end-of-test check.
          if (shares != null) ChangeNotifierProvider<SharesViewModel>.value(value: shares),
          ChangeNotifierProvider<AppLockController>.value(value: lock),
          // The screen registers a back-press guard on this (defect 63), so it is in scope here
          // exactly as it is in the app.
          ChangeNotifierProvider<NavigationController>.value(value: nav),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
            child: const Scaffold(body: SftpScreen()),
          ),
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

  testWidgets('the file controls fit a 360dp phone', (tester) async {
    // Negative control on the physical API-32 phone: the old toolbar overflowed by 48px.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree(), size: const Size(360, 720));
    await goToFiles(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('sftp.toolbarActions')), findsOneWidget);
    vm.dispose();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the file controls share one row in a short 200% landscape body', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree(), size: const Size(720, 360), textScale: 2);
    await goToFiles(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('sftp.search')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('the file controls yield when a 200% landscape body is too short for them', (
    tester,
  ) async {
    // The physical API-32 phone is 360x720dp; in landscape at 200% text, once the app bar, tab
    // chips and system bars are taken out, the browser body is around this height. The compact
    // side-by-side header was still taller than that and the surface sweep failed on it:
    // `dark-200pc-text/landscape/sftp/files: A RenderFlex overflowed by 25 pixels on the bottom`
    // (artifacts/device-tests/20260811T081441Z_android_ZF62224F8K_surface). Heights from 184 up are
    // clean; the same body overflowed at every one of them before the header gained its ceiling.
    for (final height in <double>[224, 208, 200, 192, 184]) {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree(), size: Size(720, height), textScale: 2);
      await goToFiles(tester);

      expect(tester.takeException(), isNull, reason: 'body height $height overflowed');
      // The listing must survive the squeeze — a header that simply took the whole body would
      // satisfy the overflow check and leave the user with no files.
      expect(find.byKey(const ValueKey('sftp.list')), findsOneWidget);
      vm.dispose();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
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

  testWidgets('Back walks up a folder instead of leaving the screen', (tester) async {
    // Defect 63, end to end: the decision table and the guard registration are unit-tested in
    // sftp_back_action_test.dart, and this is the wiring between them and the view model.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);
    nav.navigateTo(Screen.sftp);

    await tester.tap(find.byKey(const ValueKey('sftp.entry.docs')));
    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsOneWidget);

    expect(nav.navigateBack(), isTrue, reason: 'the screen claims the press');
    await tester.pumpAndSettle();

    expect(find.text('notes.txt'), findsOneWidget);
    expect(nav.currentScreen, Screen.sftp, reason: 'and stayed put to do it');
    vm.dispose();
  });

  testWidgets('Back at filesystem root leaves the screen', (tester) async {
    // The other half of the same rule: with nothing left to unwind the press must fall through, or
    // the file browser becomes a screen Back cannot escape.
    //
    // The boundary is `/`, not the login directory. Kotlin's handler is enabled on
    // `path != "/"` (`ui/SftpScreen.kt:1691`), so Back keeps climbing past /home/root — a home
    // directory is somewhere you were put, not a floor.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);
    nav.navigateTo(Screen.sftp);

    await vm.openPath('/');
    await tester.pumpAndSettle();

    expect(nav.navigateBack(), isTrue);
    await tester.pumpAndSettle();
    expect(nav.currentScreen, Screen.servers);
    vm.dispose();
  });

  testWidgets('Back clears a selection before it walks up', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: homeTree());
    await goToFiles(tester);
    nav.navigateTo(Screen.sftp);

    await tester.tap(find.byKey(const ValueKey('sftp.entry.docs')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('sftp.entry.report.pdf')));
    await tester.pumpAndSettle();
    expect(vm.hasSelection, isTrue);

    expect(nav.navigateBack(), isTrue);
    await tester.pumpAndSettle();

    expect(vm.hasSelection, isFalse);
    expect(
      find.text('report.pdf'),
      findsOneWidget,
      reason: 'clearing the selection must not also change directory',
    );
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

  group('the selection toolbar', () {
    testWidgets('select all takes every visible row', (tester) async {
      // `selectAllVisible` existed and was tested, and nothing in the UI ever called it.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.selectAll')));
      await tester.pumpAndSettle();

      expect(vm.selectedEntries.map((e) => e.name), ['docs', 'notes.txt']);
      vm.dispose();
    });

    testWidgets('a filtered listing selects only what is on screen', (tester) async {
      // Selecting rows the user cannot see would put files they never chose into the next delete.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);
      await tester.enterText(find.byKey(const ValueKey('sftp.search')), 'notes');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sftp.selectAll')));
      await tester.pumpAndSettle();

      expect(vm.selectedEntries.map((e) => e.name), ['notes.txt']);
      vm.dispose();
    });

    testWidgets('dotfiles are not selected while they are hidden', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.selectAll')));
      await tester.pumpAndSettle();

      expect(vm.selectedEntries.map((e) => e.name), isNot(contains('.hidden')));
      vm.dispose();
    });

    testWidgets('an already-selected folder disables the button', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.selectAll')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<IconButton>(find.byKey(const ValueKey('sftp.selectAll'))).onPressed,
        isNull,
        reason: 'a button that appears to do nothing should look like it does nothing',
      );
      vm.dispose();
    });

    testWidgets('downloading the selection is offered only when files are in it', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);
      expect(find.byKey(const ValueKey('sftp.downloadSelected')), findsNothing);

      // Long press is how a row is selected. 'docs' is a directory: it has no bytes to hand to a
      // save dialog, so the action stays hidden.
      await tester.longPress(find.byKey(const ValueKey('sftp.entry.docs')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sftp.downloadSelected')), findsNothing);

      await tester.longPress(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sftp.downloadSelected')), findsOneWidget);
      vm.dispose();
    });

    testWidgets('clearing the selection is offered once there is one', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);
      expect(find.byKey(const ValueKey('sftp.clearSelection')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sftp.selectAll')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sftp.clearSelection')));
      await tester.pumpAndSettle();

      expect(vm.selectedEntries, isEmpty);
      vm.dispose();
    });
  });

  group('navigating by path', () {
    testWidgets('a typed path is opened', (tester) async {
      // The defect: the browser had breadcrumbs and no address box, so a folder could only be
      // reached by walking to it one listing at a time.
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree()..tree['/var/log'] = [entry('syslog')];
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.editPath')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.pathInput')), '/var/log');
      await tester.tap(find.byKey(const ValueKey('sftp.pathInput.go')));
      await tester.pumpAndSettle();

      expect(vm.path, '/var/log');
      expect(find.text('syslog'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('the box opens prefilled with where you are', (tester) async {
      // So the common edit is appending or trimming a segment, not retyping the path.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.editPath')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byKey(const ValueKey('sftp.pathInput'))).controller!.text,
        '/home/root',
      );
      vm.dispose();
    });

    testWidgets('cancelling navigates nowhere and restores the crumbs', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree()..tree['/var/log'] = [entry('syslog')];
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.editPath')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.pathInput')), '/var/log');
      await tester.tap(find.byKey(const ValueKey('sftp.pathInput.cancel')));
      await tester.pumpAndSettle();

      expect(vm.path, '/home/root');
      expect(client.listed, isNot(contains('/var/log')));
      expect(find.byKey(const ValueKey('sftp.breadcrumbs')), findsOneWidget);
      vm.dispose();
    });

    testWidgets('a path that does not exist reports the failure', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final client = homeTree()..failFor = {'/nope'};
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.editPath')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.pathInput')), '/nope');
      await tester.tap(find.byKey(const ValueKey('sftp.pathInput.go')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sftp.error')), findsOneWidget);
      vm.dispose();
    });

    testWidgets('the home button returns to the remote home', (tester) async {
      // `openPath('')` resolved the home directory and nothing in the UI ever called it.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.entry.docs')));
      await tester.pumpAndSettle();
      expect(vm.path, '/home/root/docs');

      await tester.tap(find.byKey(const ValueKey('sftp.home')));
      await tester.pumpAndSettle();

      expect(vm.path, '/home/root');
      vm.dispose();
    });
  });

  group('bookmarks', () {
    testWidgets('a saved bookmark is listed with its host and opens the browser', (tester) async {
      final id = await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');
      final client = homeTree()..tree['/etc'] = [entry('hosts')];
      await pump(tester, client: client);

      // The endpoint is named on the row: the same path exists on several machines, and opening the
      // wrong one is the mistake a jump list invites.
      expect(find.text('nas'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('sftp.bookmark.host:$id./etc')));
      await tester.pumpAndSettle();

      expect(find.text('hosts'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('the tab is useful before any host is online', (tester) async {
      // The defect: the old tab said "connect a host first" and showed nothing, so the jump list was
      // unavailable in exactly the state it is most wanted.
      final id = await repo.insertServer(server(name: 'nas', status: 'offline'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');
      await pump(tester, client: homeTree());

      expect(find.byKey(ValueKey('sftp.bookmark.host:$id./etc')), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('an offline host\'s bookmark does not open', (tester) async {
      final id = await repo.insertServer(server(name: 'nas', status: 'offline'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');
      final client = homeTree()..tree['/etc'] = [entry('hosts')];
      await pump(tester, client: client);

      await tester.tap(find.byKey(ValueKey('sftp.bookmark.host:$id./etc')));
      await tester.pumpAndSettle();

      expect(find.text('hosts'), findsNothing);
      expect(client.listed, isNot(contains('/etc')));
      vm.dispose();
    });

    testWidgets('an empty list says so rather than showing a blank tab', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());

      expect(find.byKey(const ValueKey('sftp.bookmarks.empty')), findsOneWidget);
      vm.dispose();
    });

    testWidgets('the current folder can be bookmarked from the browser', (tester) async {
      final id = await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.bookmarkToggle')));
      await tester.pumpAndSettle();
      expect(vm.isBookmarked('/home/root'), isTrue);

      await tester.tap(find.byKey(const ValueKey('sftp.tab.bookmarks')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('sftp.bookmark.host:$id./home/root')), findsOneWidget);
      vm.dispose();
    });

    testWidgets('adding one files it against the endpoint that was chosen', (tester) async {
      final browsed = await repo.insertServer(server(name: 'browsed'));
      final other = await repo.insertServer(server(name: 'other', status: 'offline'));
      await pump(tester, client: homeTree());

      await tester.tap(find.byKey(const ValueKey('sftp.bookmarks.add')));
      await tester.pumpAndSettle();
      // The endpoint starts unselected, so Save cannot fire until one is picked.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('sftp.bookmark.editor.save')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('sftp.bookmark.editor.endpoint')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('other').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sftp.bookmark.editor.path')), '/srv/www');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sftp.bookmark.editor.save')));
      await tester.pumpAndSettle();

      expect(await repo.getSetting('sftp_bookmarks_$other'), '/srv/www');
      expect(await repo.getSetting('sftp_bookmarks_$browsed'), isNull);
      vm.dispose();
    });

    testWidgets('removing asks first and names the endpoint', (tester) async {
      final id = await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');
      await pump(tester, client: homeTree());

      await tester.tap(find.byKey(ValueKey('sftp.bookmark.host:$id./etc.remove')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sftp.bookmark.remove.dialog')), findsOneWidget);
      expect(find.textContaining('/etc on nas'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sftp.bookmark.remove.confirm')));
      await tester.pumpAndSettle();

      expect(await repo.getSetting('sftp_bookmarks_$id'), '');
      vm.dispose();
    });

    testWidgets('cancelling the removal keeps the bookmark', (tester) async {
      final id = await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('sftp_bookmarks_$id', '/etc');
      await pump(tester, client: homeTree());

      await tester.tap(find.byKey(ValueKey('sftp.bookmark.host:$id./etc.remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await repo.getSetting('sftp_bookmarks_$id'), '/etc');
      vm.dispose();
    });

    testWidgets('cloning keeps the original and offers its path', (tester) async {
      final from = await repo.insertServer(server(name: 'from'));
      final to = await repo.insertServer(server(name: 'to', status: 'offline'));
      await repo.insertSetting('sftp_bookmarks_$from', '/etc');
      await pump(tester, client: homeTree());

      await tester.tap(find.byKey(ValueKey('sftp.bookmark.host:$from./etc.clone')));
      await tester.pumpAndSettle();
      // Prefilled from the row, so a clone is one endpoint change rather than retyping the path.
      expect(find.widgetWithText(TextField, '/etc'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sftp.bookmark.editor.endpoint')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('to').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sftp.bookmark.editor.save')));
      await tester.pumpAndSettle();

      expect(await repo.getSetting('sftp_bookmarks_$from'), '/etc');
      expect(await repo.getSetting('sftp_bookmarks_$to'), '/etc');
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

  group('the file editor', () {
    FakeFsClient editableTree() {
      final client = homeTree();
      client.files['/home/root/notes.txt'] = 'listen 8080\n';
      return client;
    }

    testWidgets('the full file editor fits a 360dp phone at 200% text', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree(), size: const Size(360, 720), textScale: 2);
      await goToFiles(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('fileEditor.text')), findsOneWidget);
      expect(find.byKey(const ValueKey('fileEditor.editToggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('fileEditor.save')), findsOneWidget);
      vm.dispose();
    });

    /// The editor must say when a save will be a root write, ported from Kotlin's `· sudo`
    /// subtitle and `Save as root` button (`ui/SftpScreen.kt:3114`, `:3121`).
    ///
    /// Sudo mode is a screen-level toggle, so an editor opened on `/etc/nginx/nginx.conf` showed a
    /// plain "Save" while the view model wrote as root.
    testWidgets('the editor says nothing about root when sudo is off', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree(), transport: _StubShell());
      await goToFiles(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();

      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('fileEditor.save')));
      expect((save.child! as Text).data, 'Save');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('fileEditor.mode'))).data,
        isNot(contains('sudo')),
      );
    });

    testWidgets('with sudo on the editor names the root write', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree(), transport: _StubShell());
      await goToFiles(tester);
      vm.sudoMode = true;
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();

      final mode = tester.widget<Text>(find.byKey(const ValueKey('fileEditor.mode')));
      expect(mode.data, contains('sudo'));
      expect(
        mode.style?.color,
        OmniColors.red,
        reason: 'the one state where the colour is the warning',
      );

      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();
      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('fileEditor.save')));
      expect(
        (save.child! as Text).data,
        'Save as root',
        reason: '"Save" understates what the button does',
      );
    });

    testWidgets('tapping a file opens it read-only, and the pencil unlocks it', (tester) async {
      // Most visits to a config file on a server are to read it. An editor armed by default turns
      // a stray tap on a phone into an edit to something live.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fileEditor.text')), findsOneWidget);
      expect(find.textContaining('Read-only'), findsOneWidget);

      var field = tester.widget<TextField>(find.byKey(const ValueKey('fileEditor.text')));
      expect(field.readOnly, isTrue);
      expect(field.controller!.text, 'listen 8080\n');

      var save = tester.widget<FilledButton>(find.byKey(const ValueKey('fileEditor.save')));
      expect(save.onPressed, isNull, reason: 'nothing to save, and not in edit mode');

      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();

      field = tester.widget<TextField>(find.byKey(const ValueKey('fileEditor.text')));
      expect(field.readOnly, isFalse);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('fileEditor.mode'))).data,
        startsWith('Editing'),
      );

      await tester.tap(find.byKey(const ValueKey('fileEditor.close')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    /// Opens the editor on notes.txt, arms it, and types [text] into it.
    Future<void> openAndEdit(WidgetTester tester, String text) async {
      await goToFiles(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('fileEditor.text')), text);
      await tester.pumpAndSettle();
    }

    /// Delivers a real Android Back press to the topmost route.
    Future<void> pressBack(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    testWidgets('Back asks before discarding edits, as the close button does', (tester) async {
      // The defect: a modal sheet is popped by the system without consulting anything inside it, so
      // the guarded path was the button and the unguarded one was Back — the only path that loses
      // work being the one that never asked.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree(), transport: _StubShell());
      await openAndEdit(tester, 'edited by hand');

      await pressBack(tester);
      expect(find.byKey(const ValueKey('fileEditor.discard.dialog')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fileEditor.discard.cancel')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('fileEditor.text')),
        findsOneWidget,
        reason: 'Keep editing must leave the editor open',
      );
      vm.dispose();
    });

    testWidgets('Back on an unedited file closes without asking', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree(), transport: _StubShell());
      await goToFiles(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();

      await pressBack(tester);
      expect(find.byKey(const ValueKey('fileEditor.discard.dialog')), findsNothing);
      expect(find.byKey(const ValueKey('fileEditor.text')), findsNothing);
      vm.dispose();
    });

    testWidgets('edits still count after the pencil is switched off', (tester) async {
      // The guard used to require edit mode as well as a changed buffer, so disarming the pencil
      // with unsaved edits in it was a silent way to lose them. Kotlin gates on the buffer alone.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree(), transport: _StubShell());
      await openAndEdit(tester, 'edited by hand');

      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();

      await pressBack(tester);
      expect(find.byKey(const ValueKey('fileEditor.discard.dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fileEditor.discard.confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fileEditor.text')), findsNothing);
      vm.dispose();
    });

    testWidgets('an unchanged file cannot be saved', (tester) async {
      // Rewriting a file byte-for-byte still moves its mtime, which is a real change to anything
      // watching it.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();

      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('fileEditor.save')));
      expect(save.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('fileEditor.close')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    testWidgets('a save the server contradicts keeps the editor open with the edits', (
      tester,
    ) async {
      final client = editableTree()..reportedSizeOverride = 3;
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: client);
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('fileEditor.text')), 'listen 9090\n');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.save')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('fileEditor.text')),
        findsOneWidget,
        reason: 'an unconfirmed save must not close over the only copy of the edits',
      );
      expect(find.byKey(const ValueKey('fileEditor.error')), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('fileEditor.text')));
      expect(field.controller!.text, 'listen 9090\n');

      await tester.tap(find.byKey(const ValueKey('fileEditor.close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.discard.confirm')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    testWidgets('closing with unsaved edits asks first', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: editableTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.editToggle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('fileEditor.text')), 'changed\n');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('fileEditor.close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fileEditor.discard.dialog')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fileEditor.discard.cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fileEditor.text')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fileEditor.close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fileEditor.discard.confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fileEditor.text')), findsNothing);
      vm.dispose();
    });
  });

  testWidgets('a listing still in flight is not called an empty directory', (tester) async {
    // Found on a real host, not reasoned about: the first listing of a host carries the TCP
    // connect, the handshake, the auth and opening the SFTP subsystem, and for all of it the
    // browser stated "This directory is empty" about a folder holding nine files. The 2px progress
    // bar in the toolbar is not a correction — the body was asserting the opposite of it.
    final gate = Completer<List<SftpFile>>();
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: _GatedFsClient(gate));

    await tester.tap(find.byKey(const ValueKey('sftp.tab.files')));
    // Not pumpAndSettle: the progress indicator animates forever while the listing is in flight.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('sftp.loading')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sftp.empty')),
      findsNothing,
      reason: 'nothing has been read yet, so nothing is known about what is there',
    );
    expect(find.text('This directory is empty'), findsNothing);

    gate.complete([entry('notes.txt')]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sftp.list')), findsOneWidget);
    expect(find.byKey(const ValueKey('sftp.loading')), findsNothing);
    vm.dispose();
  });

  testWidgets('a folder that really is empty still says so', (tester) async {
    // The other half: once the listing has landed, "empty" is a fact and has to be stated.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, client: FakeFsClient(tree: {'/home/root': const []}));
    await goToFiles(tester);

    expect(find.byKey(const ValueKey('sftp.empty')), findsOneWidget);
    expect(find.text('This directory is empty'), findsOneWidget);
    vm.dispose();
  });

  /// Downloading a file to the device, ported from the download action in `ui/SftpScreen.kt`.
  ///
  /// `SftpViewModel.download` existed with **no caller anywhere in the UI**, so the SFTP screen had
  /// no way to get a file off a host and the Transfers tab could only show transfers some other flow
  /// had started.
  group('download to device', () {
    testWidgets('a file offers a download action', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.notes.txt.menu')));
      await tester.pumpAndSettle();

      expect(find.text('Download to device'), findsOneWidget);
    });

    testWidgets('a directory does not', (tester) async {
      // The staged download is a single file; a folder would need an archive first.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree());
      await goToFiles(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.entry.docs.menu')));
      await tester.pumpAndSettle();

      expect(find.text('Download to device'), findsNothing);
    });
  });

  /// Enabling sudo mode, ported from the gate in `ui/SftpScreen.kt:1964`.
  ///
  /// Two defects here. The dialog claimed "browsing, renaming and deleting are unchanged and still
  /// run as you", while the view model runs `mkdir`, `mv` and **`rm -rf`** as root once sudo is on —
  /// telling someone their deletes are unprivileged and then deleting as root is the worst direction
  /// for that sentence to be wrong in. And Kotlin authenticates before switching it on; Flutter only
  /// confirmed.
  group('sudo mode', () {
    Future<void> openSudoDialog(WidgetTester tester) async {
      // The toolbar lives on the Files tab; the screen opens on Bookmarks.
      vm.activeTab = SftpTab.files;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sftp.sudo')));
      await tester.pumpAndSettle();
    }

    testWidgets('the warning says every operation runs as root', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree(), transport: _StubShell());
      await openSudoDialog(tester);

      final content = tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('sftp.sudo.dialog')),
                  matching: find.byType(Text),
                )
                .at(1),
          )
          .data!;
      expect(content, contains('run as root'));
      expect(content, contains('deleting'));
      expect(
        content,
        isNot(contains('still run as you')),
        reason: 'the old wording told the user their deletes were unprivileged',
      );
    });

    testWidgets('cancelling leaves sudo off', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree(), transport: _StubShell());
      await openSudoDialog(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.sudo.cancel')));
      await tester.pumpAndSettle();

      expect(vm.sudoMode, isFalse);
    });

    testWidgets('with a stored sudo password it authenticates before switching on', (tester) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      await pump(tester, client: homeTree(), transport: _StubShell());
      await lock.load();
      await openSudoDialog(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.sudo.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sudoAuth.dialog')), findsOneWidget);
      expect(vm.sudoMode, isFalse, reason: 'not until the user is re-identified');

      await tester.tap(find.byKey(const ValueKey('sudoAuth.cancel')));
      await tester.pumpAndSettle();
      expect(vm.sudoMode, isFalse);
    });

    testWidgets('the right PIN switches it on', (tester) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      await pump(tester, client: homeTree(), transport: _StubShell());
      await lock.load();
      await openSudoDialog(tester);
      await tester.tap(find.byKey(const ValueKey('sftp.sudo.confirm')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('sudoAuth.pin')), '1234');
      await tester.tap(find.byKey(const ValueKey('sudoAuth.confirm')));
      await tester.pumpAndSettle();

      expect(vm.sudoMode, isTrue);
    });

    testWidgets('a host with no stored sudo password is not gated', (tester) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, client: homeTree(), transport: _StubShell());
      await lock.load();
      await openSudoDialog(tester);

      await tester.tap(find.byKey(const ValueKey('sftp.sudo.confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sudoAuth.dialog')), findsNothing);
      expect(vm.sudoMode, isTrue);
    });

    testWidgets('turning it off again needs no authentication', (tester) async {
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertServer(server(name: 'nas', sudoPassword: 'hunter2'));
      await pump(tester, client: homeTree(), transport: _StubShell());
      await lock.load();
      vm.activeTab = SftpTab.files;
      vm.sudoMode = true;
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sftp.sudo')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sudoAuth.dialog')), findsNothing);
      expect(vm.sudoMode, isFalse);
    });
  });
}

/// A client whose home listing does not land until the test says so.
class _GatedFsClient extends FakeFsClient {
  _GatedFsClient(this.gate);

  final Completer<List<SftpFile>> gate;

  @override
  Future<List<SftpFile>> list(String path) => gate.future;
}

/// A shell that makes `canUseSudo` true and answers the one command these tests provoke.
///
/// With sudo mode on, opening a file reads it over an exec channel rather than SFTP, so a stub that
/// throws would leave the editor unopened and the test asserting against nothing.
class _StubShell implements SshTransport {
  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) async =>
      // The real command prints a marker before the file, and `parseSudoRead` returns null without
      // it — which the view model reports as "sudo refused" and never opens the editor.
      '$sudoOutputMarker\nlisten 8080\n';

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
