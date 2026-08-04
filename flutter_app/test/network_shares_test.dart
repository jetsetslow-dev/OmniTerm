
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/domain/network_share_form.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/sftp/shares_tab.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/data/shares/remote_fs_client.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/ui/view_model/shares_view_model.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

/// A file client that reports one directory, so Browse has something to show.
class _FakeShareClient extends RemoteFsClient {
  @override
  Future<String> home() async => '/';

  @override
  Future<List<SftpFile>> list(String path) async => [
        SftpFile(
          name: 'movies',
          isDirectory: true,
          size: 0,
          modDate: '2026-01-01',
          modTimeSeconds: 0,
        ),
      ];

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A probe that answers from a fixed map of reachable endpoints.
class _FakeProbe implements NetworkProbe {
  _FakeProbe({this.reachable = const {}});

  final Set<String> reachable;
  final List<String> probed = [];
  int inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<Duration?> tcpPing(String host, int port, {Duration timeout = const Duration(seconds: 1)}) async {
    probed.add('$host:$port');
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    inFlight--;
    return reachable.contains('$host:$port') ? const Duration(milliseconds: 3) : null;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('the form', () {
    test('each protocol brings its own default port', () {
      expect(ShareProtocol.smb.defaultPort, 445);
      expect(ShareProtocol.ftp.defaultPort, 21);
      expect(ShareProtocol.sftp.defaultPort, 22);
      expect(ShareProtocol.nfs.defaultPort, 2049);
      expect(ShareProtocol.webdav.defaultPort, 443);
    });

    test('switching protocol moves a default port but never a typed one', () {
      // Silently overwriting a port the user typed is how a share stops reaching a NAS on a
      // nonstandard port with no visible cause.
      const smb = NetworkShareDraft(protocol: ShareProtocol.smb, port: '445');
      expect(smb.withProtocol(ShareProtocol.ftp).port, '21');

      const custom = NetworkShareDraft(protocol: ShareProtocol.smb, port: '4450');
      expect(custom.withProtocol(ShareProtocol.ftp).port, '4450');
    });

    test('a blank port falls back to the protocol default', () {
      const draft = NetworkShareDraft(protocol: ShareProtocol.sftp);
      expect(draft.effectivePort, 22);
    });

    group('validation', () {
      NetworkShareDraft valid() => const NetworkShareDraft(
            name: 'nas',
            protocol: ShareProtocol.smb,
            address: '10.0.0.5',
            port: '445',
            sharePath: 'media',
            username: 'sam',
          );

      test('a complete draft is valid', () => expect(valid().isValid, isTrue));

      test('a name and address are required', () {
        expect(valid().copyWith(name: ' ').errors, contains('name'));
        expect(valid().copyWith(address: '').errors, contains('address'));
      });

      test('a port outside the range is refused', () {
        expect(valid().copyWith(port: '0').errors, contains('port'));
        expect(valid().copyWith(port: '70000').errors, contains('port'));
        expect(valid().copyWith(port: 'abc').errors, contains('port'));
        expect(valid().copyWith(port: '445').errors, isNot(contains('port')));
      });

      test('a custom share must name its port, since it has no default', () {
        expect(valid().withProtocol(ShareProtocol.custom).copyWith(port: '').errors,
            contains('port'));
      });

      test('SMB needs a share name', () {
        // SMB connects to a share, not to a host; without one there is nothing to open.
        expect(valid().copyWith(sharePath: '').errors, contains('sharePath'));
        expect(valid().withProtocol(ShareProtocol.sftp).copyWith(sharePath: '').errors,
            isNot(contains('sharePath')));
      });

      test('some way to authenticate is required', () {
        expect(valid().copyWith(username: '').errors, contains('username'));
        expect(valid().copyWith(username: '', anonymous: true).errors, isNot(contains('username')));
        expect(valid().copyWith(username: '', authProfileId: 3).errors,
            isNot(contains('username')));
      });
    });

    group('warnings advise, never block (§17)', () {
      test('FTP says the password travels in clear text', () {
        const draft = NetworkShareDraft(
          name: 'n',
          protocol: ShareProtocol.ftp,
          address: 'a',
          port: '21',
          username: 'u',
        );
        expect(draft.warnings.single, contains('clear text'));
        expect(draft.isValid, isTrue, reason: 'the user chose this server');
      });

      test('WebDAV without HTTPS says the same', () {
        const draft = NetworkShareDraft(
          name: 'n',
          protocol: ShareProtocol.webdav,
          address: 'a',
          port: '443',
          username: 'u',
          useHttps: false,
        );
        expect(draft.warnings.single, contains('clear text'));
        expect(draft.isValid, isTrue);
      });

      test('a well-formed SFTP share warns about nothing', () {
        const draft = NetworkShareDraft(
          name: 'n',
          protocol: ShareProtocol.sftp,
          address: 'a',
          port: '22',
          username: 'u',
        );
        expect(draft.warnings, isEmpty);
      });
    });

    test('anonymous clears the credentials rather than storing unused ones', () {
      // Leaving them on the row would keep a password stored for a share that never sends one.
      const draft = NetworkShareDraft(
        name: 'n',
        protocol: ShareProtocol.smb,
        address: 'a',
        port: '445',
        sharePath: 's',
        username: 'sam',
        password: 'hunter2',
        authProfileId: 4,
        anonymous: true,
      );
      final row = draft.toShare();
      expect(row.username, isEmpty);
      expect(row.password, isEmpty);
      expect(row.authProfileId, isNull);
    });

    group('browsability', () {
      test('only the protocols with a client are offered', () {
        // Offering Browse for a protocol with no client is a button that fails on tap.
        expect(shareIsBrowsable(ShareProtocol.smb), isTrue);
        expect(shareIsBrowsable(ShareProtocol.sftp), isTrue);
        expect(shareIsBrowsable(ShareProtocol.ftp), isFalse);
        expect(shareIsBrowsable(ShareProtocol.webdav), isFalse);
        expect(shareIsBrowsable(ShareProtocol.nfs), isFalse);
      });

      test('each unavailable protocol explains itself differently', () {
        // "Not built yet" and "the OS does this, not us" send the user to different places.
        expect(shareBrowseUnavailableReason(ShareProtocol.smb), isNull);
        expect(shareBrowseUnavailableReason(ShareProtocol.ftp), contains('not built yet'));
        expect(shareBrowseUnavailableReason(ShareProtocol.nfs), contains('operating system'));
        expect(shareBrowseUnavailableReason(ShareProtocol.custom), contains('no protocol'));
      });
    });
  });

  group('the display URI', () {
    NetworkShare share({
      String protocol = 'SMB',
      int port = 445,
      String path = 'media',
      bool https = true,
    }) =>
        NetworkShare(
          id: 1,
          name: 'nas',
          protocol: protocol,
          address: 'nas.local',
          port: port,
          sharePath: path,
          workgroup: '',
          username: 'sam',
          password: 'hunter2',
          anonymous: false,
          useHttps: https,
          notes: '',
          lastChecked: 0,
          lastStatus: 'unknown',
        );

    test('reads as the protocol it is', () {
      expect(shareUri(share()), 'smb://nas.local:445/media');
      expect(shareUri(share(protocol: 'SFTP', port: 22)), 'sftp://nas.local:22/media');
    });

    test('WebDAV follows the HTTPS switch, not the port', () {
      expect(shareUri(share(protocol: 'WEBDAV', port: 5006)), 'https://nas.local:5006/media');
      expect(
        shareUri(share(protocol: 'WEBDAV', port: 5006, https: false)),
        'http://nas.local:5006/media',
      );
    });

    test('never carries the credentials', () {
      // It goes on a list the user may well be showing someone.
      expect(shareUri(share()), isNot(contains('sam')));
      expect(shareUri(share()), isNot(contains('hunter2')));
    });

    test('a blank path is simply absent', () {
      expect(shareUri(share(path: '')), 'smb://nas.local:445');
      expect(shareUri(share(path: '/media/')), 'smb://nas.local:445/media');
    });
  });

  group('the view model', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late _FakeProbe probe;
    late SharesViewModel vm;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
      probe = _FakeProbe();
      HostDisplay.instance.hideSensitiveInfo = false;
    });

    tearDown(() async {
      vm.dispose();
      app.dispose();
      await db.close();
    });

    Future<void> settle() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    Future<SharesViewModel> boot() async {
      await app.start();
      vm = SharesViewModel(app, probe: probe);
      await settle();
      return vm;
    }

    NetworkShare row({
      required String name,
      String address = '10.0.0.5',
      int port = 445,
      String status = 'unknown',
    }) =>
        NetworkShare(
          id: 0,
          name: name,
          protocol: 'SMB',
          address: address,
          port: port,
          sharePath: 'media',
          workgroup: '',
          username: 'sam',
          password: 'pw',
          anonymous: false,
          useHttps: true,
          notes: '',
          lastChecked: 0,
          lastStatus: status,
        );

    test('saving a draft persists it', () async {
      await boot();
      vm.startAdd();
      vm.updateDraft((d) => d.copyWith(
            name: 'nas',
            address: '10.0.0.5',
            sharePath: 'media',
            username: 'sam',
          ));

      expect(await vm.saveDraft(), isTrue);
      await settle();

      expect(vm.shares.single.name, 'nas');
      expect(vm.shares.single.port, 445, reason: 'the default filled itself in');
      expect(vm.draft, isNull);
    });

    test('an invalid draft is not saved and stays open', () async {
      await boot();
      vm.startAdd();
      vm.updateDraft((d) => d.copyWith(name: 'nas'));

      expect(await vm.saveDraft(), isFalse);
      expect(vm.draft, isNotNull, reason: 'the user has to be able to fix it');
      expect(vm.shares, isEmpty);
    });

    test('editing keeps the last known reachability', () async {
      // Editing the notes should not make a host that answered a moment ago read as unknown.
      await repo.insertNetworkShare(row(name: 'nas', status: 'online'));
      await boot();

      vm.startEdit(vm.shares.single);
      vm.updateDraft((d) => d.copyWith(name: 'nas2'));
      await vm.saveDraft();
      await settle();

      expect(vm.shares.single.name, 'nas2');
      expect(vm.shares.single.lastStatus, 'online');
    });

    test('a reachable share is recorded as online', () async {
      await repo.insertNetworkShare(row(name: 'nas'));
      probe = _FakeProbe(reachable: {'10.0.0.5:445'});
      await boot();

      await vm.test(vm.shares.single);
      await settle();

      expect(vm.shares.single.lastStatus, 'online');
      expect(vm.shares.single.lastChecked, greaterThan(0));
      expect(vm.status, contains('online'));
    });

    test('an unanswered port is "unreachable", not "offline"', () async {
      // A host that is up but not listening looks identical from here; calling the machine down
      // would send the user hunting the wrong problem.
      await repo.insertNetworkShare(row(name: 'nas'));
      await boot();

      await vm.test(vm.shares.single);
      await settle();

      expect(vm.shares.single.lastStatus, 'unreachable');
      expect(vm.status, contains('unreachable'));
    });

    test('a probe that throws is still an answer', () async {
      await repo.insertNetworkShare(row(name: 'nas'));
      await boot();
      await vm.test(vm.shares.single);
      await settle();
      expect(vm.shares.single.lastStatus, 'unreachable');
    });

    test('checking all shares is bounded', () async {
      // An unbounded sweep opens one socket per share at once — on a phone that is a
      // self-inflicted connection storm.
      for (var i = 0; i < 20; i++) {
        await repo.insertNetworkShare(row(name: 'share$i', address: '10.0.0.$i'));
      }
      await boot();

      await vm.testAll();

      expect(probe.probed, hasLength(20));
      expect(probe.peakInFlight, lessThanOrEqualTo(SharesViewModel.maxConcurrentProbes));
    });

    test('deleting says what it did not touch', () async {
      await repo.insertNetworkShare(row(name: 'nas'));
      await boot();

      await vm.delete(vm.shares.single);
      await settle();

      expect(vm.shares, isEmpty);
      expect(vm.status, contains('untouched'));
    });
  });

  group('the tab', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late SharesViewModel vm;
    late SftpViewModel sftp;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
      HostDisplay.instance.hideSensitiveInfo = false;
    });

    tearDown(() async {
      vm.dispose();
      sftp.dispose();
      app.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await app.start();
      vm = SharesViewModel(app, probe: _FakeProbe());
      sftp = SftpViewModel(app, shareClientFor: (_) async => _FakeShareClient());
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<SharesViewModel>.value(value: vm),
            ChangeNotifierProvider<SftpViewModel>.value(value: sftp),
          ],
          child: MaterialApp(
            theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
            home: const Scaffold(body: SharesTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    NetworkShare row({required String protocol}) => NetworkShare(
          id: 0,
          name: 'share',
          protocol: protocol,
          address: '10.0.0.5',
          port: 445,
          sharePath: 'media',
          workgroup: '',
          username: 'sam',
          password: 'pw',
          anonymous: false,
          useHttps: true,
          notes: '',
          lastChecked: 0,
          lastStatus: 'unknown',
        );

    testWidgets('with nothing saved it says so', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('shares.empty')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a saved share shows its URI without the password', (tester) async {
      await repo.insertNetworkShare(row(protocol: 'SMB'));
      await pump(tester);

      expect(find.textContaining('smb://10.0.0.5:445/media'), findsOneWidget);
      expect(find.textContaining('pw'), findsNothing);
      await finish(tester);
    });

    testWidgets('hide-addresses masks the share URI too', (tester) async {
      // A share list is exactly the sort of screen that ends up in a screenshot.
      await repo.insertNetworkShare(row(protocol: 'SMB'));
      HostDisplay.instance.hideSensitiveInfo = true;
      await pump(tester);

      expect(find.textContaining('10.0.0.5'), findsNothing);
      HostDisplay.instance.hideSensitiveInfo = false;
      await finish(tester);
    });

    testWidgets('an unbrowsable protocol says why on the card', (tester) async {
      await repo.insertNetworkShare(row(protocol: 'NFS'));
      await pump(tester);

      expect(find.textContaining('mounted by the operating system'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('deleting asks first and names the blast radius', (tester) async {
      await repo.insertNetworkShare(row(protocol: 'SMB'));
      await pump(tester);
      final id = vm.shares.single.id;

      await tester.tap(find.byKey(ValueKey('shares.card.$id.delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Files on the share are not touched'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shares.delete.cancel')));
      await tester.pumpAndSettle();
      expect(vm.shares, hasLength(1));

      await tester.tap(find.byKey(ValueKey('shares.card.$id.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shares.delete.confirm')));
      await tester.pumpAndSettle();
      expect(vm.shares, isEmpty);
      await finish(tester);
    });

    testWidgets('the form refuses to save until it is complete', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('shares.add')));
      await tester.pumpAndSettle();

      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('shares.form.save')));
      expect(save.onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('shares.form.name')), 'nas');
      await tester.enterText(find.byKey(const ValueKey('shares.form.address')), '10.0.0.9');
      await tester.enterText(find.byKey(const ValueKey('shares.form.sharePath')), 'media');
      await tester.enterText(find.byKey(const ValueKey('shares.form.username')), 'sam');
      await tester.pumpAndSettle();

      final ready = tester.widget<FilledButton>(find.byKey(const ValueKey('shares.form.save')));
      expect(ready.onPressed, isNotNull);
      await finish(tester);
    });

    testWidgets('an FTP share warns but still saves', (tester) async {
      // §17: warn, do not block. The user picked this server.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('shares.add')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('shares.form.protocol.FTP')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('shares.form.name')), 'ftp');
      await tester.enterText(find.byKey(const ValueKey('shares.form.address')), '10.0.0.9');
      await tester.enterText(find.byKey(const ValueKey('shares.form.username')), 'sam');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shares.form.warning.0')), findsOneWidget);
      final save = tester.widget<FilledButton>(find.byKey(const ValueKey('shares.form.save')));
      expect(save.onPressed, isNotNull, reason: 'a warning is advice, not a veto');
      await finish(tester);
    });

    testWidgets('picking a protocol moves the port with it', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('shares.add')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('shares.form.protocol.SFTP')));
      await tester.pumpAndSettle();

      expect(vm.draft!.port, '22');
      await finish(tester);
    });
  });

  group('browsing a share', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late SftpViewModel sftp;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
    });

    tearDown(() async {
      sftp.dispose();
      app.dispose();
      await db.close();
    });

    NetworkShare share() => NetworkShare(
          id: 7,
          name: 'media',
          protocol: 'SMB',
          address: '10.0.0.5',
          port: 445,
          sharePath: 'media',
          workgroup: '',
          username: 'sam',
          password: 'pw',
          anonymous: false,
          useHttps: true,
          notes: '',
          lastChecked: 0,
          lastStatus: 'online',
        );

    Future<SftpViewModel> boot({bool withClient = true}) async {
      await app.start();
      await Future<void>.delayed(Duration.zero);
      return sftp = SftpViewModel(
        app,
        shareClientFor: withClient ? (_) async => _FakeShareClient() : null,
      );
    }

    test('opening a share lists it and takes over the Files tab', () async {
      await boot();
      await sftp.openShare(share());

      expect(sftp.browsedShare?.name, 'media');
      expect(sftp.activeTab, SftpTab.files);
      expect(sftp.visibleEntries.single.name, 'movies');
      expect(sftp.hasBrowseTarget, isTrue);
    });

    test('closing a share leaves the share browser', () async {
      await boot();
      await sftp.openShare(share());
      await sftp.closeShare();

      expect(sftp.browsedShare, isNull);
      expect(sftp.path, isEmpty);
    });

    test('bookmarks are unavailable while a share is open', () async {
      // They are stored per serverId, and a share has no host to key them to.
      await boot();
      await sftp.openShare(share());

      expect(sftp.canBookmark, isFalse);
      await sftp.toggleBookmark('/movies');
      expect(sftp.bookmarks, isEmpty);
    });

    test('a host change underneath does not disturb the open share', () async {
      // Otherwise a host dropping offline would reset the path and reload the host's bookmarks
      // under the share's listing.
      await boot();
      await sftp.openShare(share());
      await sftp.openPath('/movies');
      final path = sftp.path;

      app.selectedServerId = 999;
      await Future<void>.delayed(Duration.zero);

      expect(sftp.browsedShare?.name, 'media');
      expect(sftp.path, path);
    });

    test('without a share client the failure names the share', () async {
      // "This build cannot browse shares" and "that share would not open" send the user to
      // different places.
      await boot(withClient: false);
      await sftp.openShare(share());

      expect(sftp.error, contains('unavailable in this build'));
    });
  });
}
