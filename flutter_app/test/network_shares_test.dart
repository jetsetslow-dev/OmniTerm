import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/domain/network_share_form.dart';
import 'package:omniterm/l10n/app_localizations.dart';
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
    SftpFile(name: 'movies', isDirectory: true, size: 0, modDate: '2026-01-01', modTimeSeconds: 0),
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
  Future<Duration?> tcpPing(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
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

    // Kotlin's `validateDraft`: one message at a time, in Kotlin's order.
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

      test('a name is optional, an address is not', () {
        expect(valid().copyWith(name: ' ').isValid, isTrue);
        expect(valid().copyWith(address: '').validationError, 'Address is required.');
      });

      test('a port outside the range is refused', () {
        for (final port in ['0', '70000', 'abc', '']) {
          expect(
            valid().copyWith(port: port).validationError,
            'Port must be between 1 and 65535.',
            reason: port,
          );
        }
        expect(valid().copyWith(port: '445').isValid, isTrue);
      });

      test('a custom share needs no port', () {
        expect(valid().withProtocol(ShareProtocol.custom).copyWith(port: '').isValid, isTrue);
      });

      test('SMB needs a share path', () {
        // SMB connects to a share, not to a host; without one there is nothing to open.
        expect(
          valid().copyWith(sharePath: ' / ').validationError,
          'SMB needs a Share/path value such as Public or Media.',
        );
        expect(valid().withProtocol(ShareProtocol.sftp).copyWith(sharePath: '').isValid, isTrue);
      });

      test('SFTP cannot be anonymous, because SSH has no anonymous mode', () {
        final sftp = valid().withProtocol(ShareProtocol.sftp).copyWith(anonymous: true);
        expect(sftp.validationError, 'SFTP needs a username or credential profile.');
        expect(valid().copyWith(anonymous: true).isValid, isTrue, reason: 'SMB guest access');
      });

      test('switching to SFTP clears anonymous rather than trapping the draft', () {
        final trapped = valid().copyWith(anonymous: true).withProtocol(ShareProtocol.sftp);
        expect(trapped.anonymous, isFalse);
        expect(trapped.isValid, isTrue);
      });

      test('switching to WebDAV turns HTTPS on', () {
        final webdav = valid().copyWith(useHttps: false).withProtocol(ShareProtocol.webdav);
        expect(webdav.useHttps, isTrue);
      });

      test('some way to authenticate is required', () {
        expect(
          valid().copyWith(username: '').validationError,
          'Username is required when anonymous login is off and no profile is selected.',
        );
        expect(valid().copyWith(username: '', anonymous: true).isValid, isTrue);
        expect(valid().copyWith(username: '', authProfileId: 3).isValid, isTrue);
      });
    });

    group('warnings advise, never block', () {
      test('FTP with credentials warns', () {
        const draft = NetworkShareDraft(
          protocol: ShareProtocol.ftp,
          address: 'a',
          port: '21',
          username: 'u',
        );
        expect(draft.warnsFtpCleartext, isTrue);
        expect(draft.copyWith(anonymous: true).warnsFtpCleartext, isFalse);
        expect(draft.isValid, isTrue, reason: 'the user chose this server');
      });

      test('WebDAV without HTTPS warns when a password would be sent', () {
        const draft = NetworkShareDraft(
          protocol: ShareProtocol.webdav,
          address: 'a',
          port: '80',
          username: 'u',
          useHttps: false,
        );
        expect(draft.warnsWebDavCleartext, isTrue);
        expect(draft.copyWith(useHttps: true).warnsWebDavCleartext, isFalse);
        expect(draft.copyWith(anonymous: true).warnsWebDavCleartext, isFalse);
        expect(draft.isValid, isTrue);
      });
    });

    group('saving, as Kotlin\'s persistNetworkShare', () {
      test('anonymous clears the credentials rather than storing unused ones', () {
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
        expect(draft.profileToCreate, isNull);
      });

      test('a blank name becomes the share URI, and the path loses its leading slash', () {
        const draft = NetworkShareDraft(
          protocol: ShareProtocol.smb,
          address: ' 10.0.0.5 ',
          port: '445',
          sharePath: '/media',
          anonymous: true,
        );
        final row = draft.toShare();
        expect(row.name, 'smb://10.0.0.5');
        expect(row.sharePath, 'media');
      });

      test('typed credentials become a reusable profile the share points at', () {
        const draft = NetworkShareDraft(
          name: 'NAS',
          protocol: ShareProtocol.smb,
          address: '10.0.0.5',
          port: '445',
          sharePath: 'media',
          username: 'sam',
          password: 'pw',
        );
        final profile = draft.profileToCreate!;
        expect(profile.profileName, 'Network Share - NAS');
        expect(profile.groupName, 'Network Shares');
        expect(profile.username, 'sam');
        expect(profile.password, 'pw');

        final row = draft.toShare(createdProfileId: 7);
        expect(row.authProfileId, 7);
        expect(row.username, isEmpty, reason: 'the profile holds the credentials now');
        expect(row.password, isEmpty);
      });

      test('HTTPS is stored only for WebDAV', () {
        const ftp = NetworkShareDraft(
          protocol: ShareProtocol.ftp,
          address: 'a',
          port: '21',
          anonymous: true,
        );
        expect(ftp.toShare().useHttps, isFalse);
      });
    });

    group('browsability', () {
      test('all four userspace file protocols are offered', () {
        // Offering Browse for a protocol with no client is a button that fails on tap.
        expect(shareIsBrowsable(ShareProtocol.smb), isTrue);
        expect(shareIsBrowsable(ShareProtocol.sftp), isTrue);
        expect(shareIsBrowsable(ShareProtocol.ftp), isTrue);
        expect(shareIsBrowsable(ShareProtocol.webdav), isTrue);
        expect(shareIsBrowsable(ShareProtocol.nfs), isFalse);
      });
    });
  });

  group('the display URI', () {
    NetworkShare share({
      String protocol = 'SMB',
      int port = 445,
      String path = 'media',
      bool https = true,
    }) => NetworkShare(
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
    }) => NetworkShare(
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
      vm.updateDraft(
        (d) => d.copyWith(name: 'nas', address: '10.0.0.5', sharePath: 'media', username: 'sam'),
      );

      expect(await vm.saveDraft(), isTrue);
      await settle();

      expect(vm.shares.single.name, 'nas');
      expect(vm.shares.single.port, 445, reason: 'the default filled itself in');
      expect(vm.draft, isNull);
      expect(vm.status, 'Saved nas.');
    });

    test('a new share starts as Kotlin\'s: SMB on 445, anonymous, HTTPS off', () async {
      await boot();
      vm.startAdd();

      expect(vm.draft!.protocol, ShareProtocol.smb);
      expect(vm.draft!.port, '445');
      expect(vm.draft!.anonymous, isTrue);
      expect(vm.draft!.useHttps, isFalse);
    });

    test('typed credentials are saved as a Network Shares profile', () async {
      await boot();
      vm.startAdd();
      vm.updateDraft(
        (d) => d.copyWith(
          name: 'nas',
          address: '10.0.0.5',
          sharePath: 'media',
          anonymous: false,
          username: 'sam',
          password: 'pw',
        ),
      );

      expect(await vm.saveDraft(), isTrue);
      await settle();

      final profile = (await repo.getAllProfiles()).single;
      expect(profile.profileName, 'Network Share - nas');
      expect(profile.groupName, 'Network Shares');
      expect(profile.password, 'pw');
      final share = vm.shares.single;
      expect(share.authProfileId, profile.id);
      expect(share.username, isEmpty);
      expect(share.password, isEmpty);
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

  group('scanning the network for shares', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late SharesViewModel vm;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
    });

    tearDown(() async {
      vm.dispose();
      app.dispose();
      await db.close();
    });

    Future<SharesViewModel> boot({Set<String> reachable = const {}}) async {
      await app.start();
      vm = SharesViewModel(app, probe: _FakeProbe(reachable: reachable));
      await Future<void>.delayed(Duration.zero);
      return vm;
    }

    test('a host answering on 445 is offered as an SMB share', () async {
      await boot(reachable: {'192.168.1.20:445'});

      await vm.scanForShares('192.168.1.0/24');

      expect(vm.scanHits.single.protocol, 'SMB');
      expect(vm.scanHits.single.address, '192.168.1.20');
      expect(vm.scanning, isFalse);
      expect(vm.scanStatus, 'Scan complete: 1 candidate share service(s).');
    });

    test('a quiet subnet says so rather than looking unfinished', () async {
      await boot();

      await vm.scanForShares('192.168.1.0/24');

      expect(vm.scanHits, isEmpty);
      expect(vm.scanStatus, 'Scan complete: 0 candidate share service(s).');
    });

    test('only the selected protocols are probed', () async {
      // The whole point of the toggles: a full sweep is 254 addresses times six ports.
      await boot();
      await vm.toggleScanProtocol('FTP');
      await vm.toggleScanProtocol('SFTP');
      await vm.toggleScanProtocol('NFS');
      await vm.toggleScanProtocol('WEBDAV');

      await vm.scanForShares('192.168.1.0/24');

      final probe = vm.probe as _FakeProbe;
      expect(probe.probed.every((p) => p.endsWith(':445')), isTrue);
      expect(vm.scanProtocols, ['SMB']);
    });

    test('the last protocol cannot be turned off', () async {
      // A scan with nothing selected probes nothing and reports "none found", which is
      // indistinguishable from a quiet network.
      await boot();
      for (final protocol in ['FTP', 'SFTP', 'NFS', 'WEBDAV', 'SMB']) {
        await vm.toggleScanProtocol(protocol);
      }

      expect(vm.scanProtocols, ['SMB']);
    });

    test('the protocol choice is persisted under the Kotlin key', () async {
      await boot();
      await vm.toggleScanProtocol('NFS');

      expect(await repo.getSetting('share_scan_protocols'), isNot(contains('NFS')));
    });

    test('a stored choice is restored', () async {
      await repo.insertSetting('share_scan_protocols', 'SMB,NFS');
      await boot();

      await vm.loadScanSettings();

      expect(vm.scanProtocols, ['SMB', 'NFS']);
    });

    test('a name without a mask probes that one host, as Kotlin does', () async {
      await boot(reachable: {'nas.local:445'});

      await vm.scanForShares('nas.local');

      final probe = vm.probe as _FakeProbe;
      expect(probe.probed.every((p) => p.startsWith('nas.local:')), isTrue);
      expect(vm.scanHits.single.address, 'nas.local');
    });

    test('a mask other than /24 is refused without probing anything', () async {
      await boot();

      await vm.scanForShares('10.0.0.0/16');

      expect((vm.probe as _FakeProbe).probed, isEmpty);
      expect(
        vm.scanStatus,
        'Enter a /24 subnet like 192.168.1.0/24, or leave it blank on Wi-Fi/LAN.',
      );
      expect(vm.scanning, isFalse);
    });

    test('a blank subnet probes the hosts the LAN sweep found', () async {
      await boot(reachable: {'192.168.1.20:21'});

      await vm.scanForShares(' ', lanTargets: () async => ['192.168.1.20', '192.168.1.30']);

      final probed = (vm.probe as _FakeProbe).probed.map((p) => p.split(':').first).toSet();
      expect(probed, {'192.168.1.20', '192.168.1.30'});
      expect(vm.scanHits.single.protocol, 'FTP');
    });

    test('a blank subnet with no network to scan says what to enter', () async {
      await boot();

      await vm.scanForShares('', lanTargets: () async => const []);

      expect(
        vm.scanStatus,
        'Enter a /24 subnet like 192.168.1.0/24, or leave it blank on Wi-Fi/LAN.',
      );
    });

    test('a hit that needs no path or account is saved as a guest share, as found', () async {
      await boot(reachable: {'192.168.1.20:21'});
      await vm.scanForShares('192.168.1.20');

      await vm.saveFromScan(vm.scanHits.single);

      final saved = (await repo.getAllNetworkShares()).single;
      expect(saved.name, 'FTP on 192.168.1.20:21');
      expect(saved.anonymous, isTrue);
      expect(saved.lastStatus, 'online', reason: 'the scan just found it answering');
      expect(vm.scanHits, isEmpty, reason: 'a saved hit leaves the list');
    });

    test('SMB and SFTP hits are not saved without the form', () async {
      await boot(reachable: {'192.168.1.20:445'});
      await vm.scanForShares('192.168.1.20');

      await vm.saveFromScan(vm.scanHits.single);

      expect(await repo.getAllNetworkShares(), isEmpty);
      expect(vm.scanStatus, 'SMB needs configuration before saving.');
    });

    test('a share configured from a hit is saved as seen online', () async {
      await boot(reachable: {'192.168.1.20:445'});
      await vm.scanForShares('192.168.1.20');
      vm.startAddFromScan(vm.scanHits.single);
      vm.updateDraft((d) => d.copyWith(sharePath: 'media'));

      expect(await vm.saveDraft(), isTrue);

      expect((await repo.getAllNetworkShares()).single.lastStatus, 'online');
    });

    test('a second scan while one is running is ignored', () async {
      await boot(reachable: {'192.168.1.20:445'});

      final first = vm.scanForShares('192.168.1.0/24');
      await vm.scanForShares('10.0.0.0/24');
      await first;

      // The second call returned immediately rather than clearing the first sweep's results.
      expect(vm.scanHits, hasLength(1));
    });

    test('adding from a hit prefills the endpoint and nothing it cannot know', () async {
      // A port probe says something is listening, not what it exports or who may read it. Guessing
      // either would save a share that fails on first use with no clue why.
      await boot(reachable: {'192.168.1.20:445'});
      await vm.scanForShares('192.168.1.0/24');

      vm.startAddFromScan(vm.scanHits.single);

      expect(vm.draft!.name, 'SMB on 192.168.1.20:445', reason: "Kotlin names it after the hit");
      expect(vm.draft!.address, '192.168.1.20');
      expect(vm.draft!.port, '445');
      expect(vm.draft!.protocol, ShareProtocol.smb);
      expect(vm.draft!.sharePath, isEmpty);
      expect(vm.draft!.username, isEmpty);
      expect(vm.draft!.password, isEmpty);
      expect(vm.draft!.anonymous, isTrue, reason: "Kotlin's scan draft starts as guest access");
    });

    test('an SFTP hit is never anonymous', () async {
      await boot(reachable: {'192.168.1.20:22'});
      await vm.scanForShares('192.168.1.0/24');

      vm.startAddFromScan(vm.scanHits.single);

      expect(vm.draft!.anonymous, isFalse);
    });

    test('a WebDAV hit on 443 comes back with HTTPS on', () async {
      await boot(reachable: {'192.168.1.20:443'});
      await vm.scanForShares('192.168.1.0/24');

      vm.startAddFromScan(vm.scanHits.single);

      expect(vm.draft!.useHttps, isTrue);
    });

    test('a WebDAV hit on 80 does not claim to be HTTPS', () async {
      await boot(reachable: {'192.168.1.20:80'});
      await vm.scanForShares('192.168.1.0/24');

      vm.startAddFromScan(vm.scanHits.single);

      expect(vm.draft!.useHttps, isFalse);
    });

    test('progress is reported so a long sweep does not look hung', () async {
      await boot();
      await vm.scanForShares('192.168.1.0/24');

      expect(vm.scanProgress, 1.0);
    });
  });

  group('the tab', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late SharesViewModel vm;
    late SftpViewModel sftp;
    late _FakeProbe probe;

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

    Future<void> pump(WidgetTester tester, {Set<String> reachable = const {}}) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await app.start();
      probe = _FakeProbe(reachable: reachable);
      vm = SharesViewModel(app, probe: probe);
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
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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

    Future<void> scan(WidgetTester tester, String input) async {
      await tester.tap(find.byKey(const ValueKey('shares.scan.open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('shares.form.scanInput')), input);
      await tester.tap(find.byKey(const ValueKey('shares.scan.start')));
      // Six ports on one host, each fake probe taking 5 ms.
      for (var i = 0; i < 10 && vm.scanning; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets("scanning opens Kotlin's LAN share scan dialog", (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('shares.scan.open')));
      await tester.pumpAndSettle();

      expect(find.text('Scan LAN for shares'), findsOneWidget);
      expect(find.text('LAN share scan'), findsOneWidget);
      expect(find.text('Subnet or host'), findsOneWidget);
      expect(find.text('Scan LAN shares'), findsOneWidget);
      expect(find.text('No shares yet - run a scan.'), findsOneWidget);
      expect(find.textContaining('untick protocols to cut noise'), findsOneWidget);
      for (final protocol in ['SMB', 'FTP', 'SFTP', 'NFS', 'WEBDAV']) {
        expect(find.byKey(ValueKey('shares.scan.protocol.$protocol')), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('shares.scan.close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shares.scan.dialog')), findsNothing);
      await finish(tester);
    });

    testWidgets('an FTP hit is saved from the dialog, which then closes', (tester) async {
      await pump(tester, reachable: {'10.0.0.7:21'});
      await scan(tester, '10.0.0.7');

      expect(find.text('10.0.0.7 · FTP'), findsOneWidget);
      expect(find.text('Rescan LAN shares'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shares.scan.pick.10.0.0.7:21')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shares.scan.dialog')), findsNothing);
      expect(find.text('FTP on 10.0.0.7:21'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an SMB hit opens the form to add its path', (tester) async {
      await pump(tester, reachable: {'10.0.0.7:445'});
      await scan(tester, '10.0.0.7');

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('shares.scan.pick.10.0.0.7:445')),
          matching: find.text('Configure'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('shares.scan.pick.10.0.0.7:445')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shares.scan.dialog')), findsNothing);
      expect(find.text('Add network share'), findsOneWidget);
      expect(vm.draft!.address, '10.0.0.7');
      expect(await repo.getAllNetworkShares(), isEmpty, reason: 'nothing is saved until Save');
      await finish(tester);
    });

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

    testWidgets('an unbrowsable protocol disables Browse and says why', (tester) async {
      await repo.insertNetworkShare(row(protocol: 'NFS'));
      await pump(tester);
      final id = vm.shares.single.id;

      final browse = tester.widget<IconButton>(find.byKey(ValueKey('shares.card.$id.browse')));
      expect(browse.onPressed, isNull, reason: 'disabled, not hidden, as in Kotlin');
      expect(browse.tooltip, 'Browsing not supported for NFS');
      await finish(tester);
    });

    testWidgets('the card reads as Kotlin\'s: path, protocol, sign-in and status', (tester) async {
      await repo.insertNetworkShare(row(protocol: 'SMB'));
      await pump(tester);
      final id = vm.shares.single.id;

      expect(find.text('media · SMB · sam'), findsOneWidget);
      expect(find.text('Unknown'), findsOneWidget, reason: 'never checked');
      expect(
        tester.widget<IconButton>(find.byKey(ValueKey('shares.card.$id.edit'))).tooltip,
        'Edit share',
      );
      await finish(tester);
    });

    testWidgets('a share signing in with a profile names it', (tester) async {
      final profileId = await repo.insertProfile(
        const CredentialProfile(
          id: 0,
          profileName: 'NAS admin',
          username: 'sam',
          authType: 'password',
          password: 'pw',
          groupName: 'Network Shares',
        ),
      );
      await repo.insertNetworkShare(
        row(protocol: 'SMB').copyWith(authProfileId: Value(profileId), username: '', password: ''),
      );
      await pump(tester);

      expect(find.text('media · SMB · profile: NAS admin'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('pulling the list down checks every share', (tester) async {
      await repo.insertNetworkShare(row(protocol: 'SMB'));
      await pump(tester);
      final id = vm.shares.single.id;

      // RefreshIndicator arms after about a sixth of the viewport; this one is 2200px tall.
      await tester.fling(find.byKey(const ValueKey('shares.list')), const Offset(0, 900), 1000);
      await tester.pumpAndSettle();

      expect(probe.probed, ['10.0.0.5:445']);
      expect(find.byKey(ValueKey('shares.card.$id.status')), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
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

    Future<void> openForm(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('shares.add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shares.form.dialog')), findsOneWidget);
    }

    Future<void> pickProtocol(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(const ValueKey('shares.form.protocol')));
      await tester.pumpAndSettle();
      // The open menu holds a second copy of each item; the last one is the tappable entry.
      await tester.tap(find.byKey(ValueKey('shares.form.protocol.$id')).last);
      await tester.pumpAndSettle();
    }

    VoidCallback? saveButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('shares.form.save'))).onPressed;

    Checkbox anonymousBox(WidgetTester tester) => tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const ValueKey('shares.form.anonymous')),
        matching: find.byType(Checkbox),
      ),
    );

    testWidgets('the form opens as Kotlin\'s: anonymous, so no credential fields', (tester) async {
      await pump(tester);
      await openForm(tester);

      expect(find.text('Add network share'), findsOneWidget);
      expect(anonymousBox(tester).value, isTrue);
      expect(find.byKey(const ValueKey('shares.form.username')), findsNothing);
      expect(find.byKey(const ValueKey('shares.form.profile.new')), findsNothing);
      await finish(tester);
    });

    testWidgets('the form refuses to save until it is complete', (tester) async {
      await pump(tester);
      await openForm(tester);
      expect(saveButton(tester), isNull);

      await tester.enterText(find.byKey(const ValueKey('shares.form.address')), '10.0.0.9');
      await tester.pumpAndSettle();
      expect(saveButton(tester), isNull, reason: 'SMB still needs a share path');

      await tester.enterText(find.byKey(const ValueKey('shares.form.sharePath')), 'media');
      await tester.pumpAndSettle();
      expect(saveButton(tester), isNotNull, reason: 'a name is optional');

      await tester.tap(find.byKey(const ValueKey('shares.form.save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shares.form.dialog')), findsNothing);
      expect(vm.shares.single.name, 'smb://10.0.0.9', reason: "Kotlin's blank-name default");
      await finish(tester);
    });

    testWidgets('turning anonymous off asks for credentials, from the box or the row', (
      tester,
    ) async {
      await pump(tester);
      await openForm(tester);

      // The checkbox itself, not only its row: a tap on the box must not be swallowed.
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(vm.draft!.anonymous, isFalse);
      expect(find.byKey(const ValueKey('shares.form.username')), findsOneWidget);
      expect(find.byKey(const ValueKey('shares.form.profile.new')), findsOneWidget);

      await tester.tap(find.text('Anonymous / guest login'));
      await tester.pumpAndSettle();
      expect(vm.draft!.anonymous, isTrue);
      await finish(tester);
    });

    testWidgets('an FTP share warns but still saves', (tester) async {
      // §17: warn, do not block. The user picked this server.
      await pump(tester);
      await openForm(tester);

      await pickProtocol(tester, 'FTP');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('shares.form.address')), '10.0.0.9');
      await tester.enterText(find.byKey(const ValueKey('shares.form.username')), 'sam');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shares.form.warning.ftp')), findsOneWidget);
      expect(saveButton(tester), isNotNull, reason: 'a warning is advice, not a veto');
      await finish(tester);
    });

    testWidgets('WebDAV turns HTTPS on, and turning it off warns', (tester) async {
      await pump(tester);
      await openForm(tester);
      await pickProtocol(tester, 'WEBDAV');
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      final toggle = find.descendant(
        of: find.byKey(const ValueKey('shares.form.useHttps')),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(
        tester.widget<Switch>(toggle).onChanged,
        isNotNull,
        reason: 'a switch without a callback paints disabled',
      );
      expect(find.byKey(const ValueKey('shares.form.warning.webdav')), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(vm.draft!.useHttps, isFalse);
      expect(find.byKey(const ValueKey('shares.form.warning.webdav')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the anonymous toggle is not offered for SFTP', (tester) async {
      // Refusing on save would be too late and too confusing: the form hides the username fields
      // the moment anonymous goes on, so the user is told to fix a field they can no longer see.
      await pump(tester);
      await openForm(tester);

      await pickProtocol(tester, 'SFTP');
      expect(anonymousBox(tester).value, isFalse, reason: 'picking SFTP clears it');
      expect(anonymousBox(tester).onChanged, isNull);
      expect(
        tester.widget<InkWell>(find.byKey(const ValueKey('shares.form.anonymous'))).onTap,
        isNull,
      );

      await pickProtocol(tester, 'SMB');
      expect(
        anonymousBox(tester).onChanged,
        isNotNull,
        reason: 'SMB guest access is real, and the toggle must come back',
      );
      await finish(tester);
    });

    testWidgets('picking a protocol moves the port with it', (tester) async {
      await pump(tester);
      await openForm(tester);

      await pickProtocol(tester, 'SFTP');

      expect(vm.draft!.port, '22');
      final port = tester.widget<TextField>(find.byKey(const ValueKey('shares.form.port')));
      expect(port.controller!.text, '22', reason: 'the field shows the port it moved to');
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

    test('a share is bookmarkable under its own key', () async {
      // Not the host's: `/etc` on the machine you were browsing is not a path on this share, and
      // the two must never write into each other's row.
      await boot();
      await sftp.openShare(share());

      expect(sftp.canBookmark, isTrue);
      await sftp.toggleBookmark('/movies');

      expect(sftp.bookmarks, ['/movies']);
      expect(await repo.getSetting('share_bookmarks_7'), '/movies');
      expect(await repo.getSetting('sftp_bookmarks_7'), isNull);
    });

    test('a share does not inherit the host bookmark defaults', () async {
      // /root and /var/log are paths on a Unix host. Offered on an SMB share they would be five
      // bookmarks that all fail to open.
      await boot();
      await sftp.openShare(share());

      expect(sftp.bookmarks, isEmpty);
    });

    test('opening a share loads the bookmarks that share already had', () async {
      await boot();
      await repo.insertSetting('share_bookmarks_7', '/movies|||/music');
      await sftp.openShare(share());

      expect(sftp.bookmarks, ['/movies', '/music']);
      expect(sftp.isBookmarked('/music'), isTrue);
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
