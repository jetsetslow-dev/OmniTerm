import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_tunnel_manager.dart';
import 'package:omniterm/domain/network_tools.dart';
import 'package:omniterm/domain/external_ui_requests.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/l10n/app_localizations.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/tools/network_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/network_view_model.dart';
import 'package:provider/provider.dart';

import 'network_view_model_test.dart' show FakeDeviceCommands, FakeProbe, aRecordResponse;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late NetworkViewModel vm;
  late NavigationController navigation;
  late ExternalUiRequests externalRequests;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    navigation = NavigationController();
    externalRequests = ExternalUiRequests();
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, FakeProbe probe, {SshTunnelManager? tunnels}) async {
    await app.start();
    vm = NetworkViewModel(
      app,
      probe: probe,
      deviceCommands: FakeDeviceCommands(),
      tunnels: tunnels,
      arpReader: () async => const {},
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<NetworkViewModel>.value(value: vm),
          ChangeNotifierProvider<NavigationController>.value(value: navigation),
          ChangeNotifierProvider<ExternalUiRequests>.value(value: externalRequests),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: NetworkScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Cancelling a drift `watch` subscription schedules zero-duration timers.
  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// Switches to [tab] through the view model.
  ///
  /// Not by tapping the chip: the strip scrolls, and since WHOIS was added it is wider than a phone,
  /// so a chip that has not been scrolled to is not built and the tap lands on nothing. These tests
  /// are about what each tab *shows*; that the chips are all reachable is its own test below, which
  /// does scroll to each one.
  Future<void> goTo(WidgetTester tester, NetworkTab tab) async {
    vm.activeTab = tab;
    await tester.pumpAndSettle();
  }

  Future<void> waitForScan(WidgetTester tester) async {
    while (vm.scanning) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
  }

  Server host({required String name}) => Server(
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
    status: 'online',
    authStatus: 'ok',
  );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Kotlin scaffold and every tab is reachable', (tester) async {
    await pump(tester, FakeProbe());
    expect(find.text('Network tools'), findsOneWidget);

    for (final tab in NetworkTab.values) {
      final chip = find.byKey(ValueKey('network.tab.${tab.name}'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(vm.activeTab, tab);
      expect(find.text(NetworkScreen.tabLabels[tab]!), findsOneWidget);
    }
    await finish(tester);
  });

  group('host scan', () {
    testWidgets('one button sweeps this device\'s own network, as Kotlin does', (tester) async {
      await pump(
        tester,
        FakeProbe(
          open: {'192.168.1.5:22', '192.168.1.5:80'},
          names: {'192.168.1.5': 'nas.local'},
          local: '192.168.1.42',
        ),
      );
      expect(find.text('No hosts yet — run a scan.'), findsOneWidget);
      expect(find.text('Scan network'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('network.scan.button')));
      await waitForScan(tester);

      expect(vm.subnetPrefix, '192.168.1');
      expect(find.byKey(const ValueKey('network.scan.host.192.168.1.5')), findsOneWidget);
      expect(find.text('nas.local'), findsOneWidget);
      expect(find.text('Open ports: 22, 80'), findsOneWidget);
      expect(find.text('MAC unavailable'), findsWidgets);
      expect(find.text('Rescan network'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a result offers Kotlin\'s actions and port scan starts with its ports', (
      tester,
    ) async {
      await pump(tester, FakeProbe(open: {'192.168.1.5:22'}, local: '192.168.1.42'));
      await tester.tap(find.byKey(const ValueKey('network.scan.button')));
      await waitForScan(tester);

      await tester.tap(find.byKey(const ValueKey('network.scan.host.192.168.1.5')));
      await tester.pumpAndSettle();
      expect(find.text('Add as OmniTerm host'), findsOneWidget);
      expect(find.text('SSH is open on port 22'), findsOneWidget);
      expect(find.text('Includes the 1 port(s) the sweep found open'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('network.scan.action.portScan')));

      expect(vm.activeTab, NetworkTab.portScan);
      expect(vm.portScanTarget, '192.168.1.5');
      expect(vm.portResults, isNotEmpty, reason: 'actions start the chosen tool');
      await finish(tester);
    });

    testWidgets('a fresh sweep is reused by the LAN host picker', (tester) async {
      await pump(tester, FakeProbe(open: {'192.168.1.5:22'}, local: '192.168.1.42'));
      await tester.tap(find.byKey(const ValueKey('network.scan.button')));
      await waitForScan(tester);
      expect(vm.isScanFresh, isTrue);

      await goTo(tester, NetworkTab.ping);
      await tester.tap(find.byKey(const ValueKey('network.picker')));
      await tester.pumpAndSettle();
      expect(vm.scanning, isFalse, reason: 'a fresh sweep must not be repeated');
      expect(find.text('Pick a LAN host'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('network.scan.host.192.168.1.5')).last);
      await tester.pumpAndSettle();

      expect(vm.pingTarget, '192.168.1.5');
      await finish(tester);
    });
  });

  group('shared target', () {
    testWidgets('Ping, Traceroute and Port Scan share one target', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.ping);
      await tester.enterText(find.byKey(const ValueKey('network.target')), '10.0.0.9');
      await tester.pump();

      await goTo(tester, NetworkTab.traceroute);
      expect(find.widgetWithText(TextField, '10.0.0.9'), findsOneWidget);
      await goTo(tester, NetworkTab.portScan);
      expect(find.widgetWithText(TextField, '10.0.0.9'), findsOneWidget);
      await finish(tester);
    });
  });

  group('ping', () {
    testWidgets('Start Ping waits for a target and streams the output', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.ping);
      final start = find.byKey(const ValueKey('network.ping.start'));
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      expect(find.text('Tries (0 = keep pinging until stopped)'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('network.target')), '10.0.0.1');
      await tester.pump();
      await tapVisible(tester, start);

      expect(find.textContaining('icmp_seq=1'), findsOneWidget);
      expect(find.textContaining('0% packet loss'), findsOneWidget);
      await finish(tester);
    });
  });

  group('port scan', () {
    testWidgets('lists every probed port as Open or Closed, as Kotlin does', (tester) async {
      await pump(tester, FakeProbe(open: {'10.0.0.1:22', '10.0.0.1:443'}));
      await goTo(tester, NetworkTab.portScan);

      await tester.enterText(find.byKey(const ValueKey('network.target')), '10.0.0.1');
      await tester.enterText(find.byKey(const ValueKey('network.portScan.ports')), '22,80,443');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('network.portScan.start')));

      expect(find.text('Port 22'), findsOneWidget);
      expect(find.text('Port 80'), findsOneWidget);
      expect(find.text('Open'), findsNWidgets(2));
      expect(find.text('Closed'), findsOneWidget);
      await finish(tester);
    });
  });

  group('wake on LAN', () {
    testWidgets('a target is configured and woken with Kotlin wording', (tester) async {
      final probe = FakeProbe();
      await pump(tester, probe);
      await goTo(tester, NetworkTab.wakeOnLan);
      expect(find.text('Saved targets'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('network.wol.add')));
      await tester.pumpAndSettle();
      expect(find.text('Configure WOL Pointer'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('network.wol.editor.name')), 'nas');
      await tester.enterText(
        find.byKey(const ValueKey('network.wol.editor.mac')),
        'aa:bb:cc:dd:ee:ff',
      );
      await tester.enterText(find.byKey(const ValueKey('network.wol.editor.ip')), '192.168.4.20');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('network.wol.editor.save')));

      expect(find.text('nas'), findsOneWidget);
      expect(find.text('MAC: aa:bb:cc:dd:ee:ff · Port 9 · 192.168.4.20'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('network.wol.${vm.wolTargets.single.id}.wake')));
      await tester.pumpAndSettle();
      expect(find.text('Send wake packet?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('network.wol.wakeDialog.confirm')));
      await tester.pumpAndSettle();

      expect(probe.sentPackets, hasLength(1));
      expect(find.text('Magic packet sent to nas'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a bad MAC disables Add configuration', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.wakeOnLan);
      await tester.tap(find.byKey(const ValueKey('network.wol.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('network.wol.editor.name')), 'nas');
      await tester.enterText(find.byKey(const ValueKey('network.wol.editor.mac')), 'nope');
      await tester.pump();

      final save = find.byKey(const ValueKey('network.wol.editor.save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(vm.wolTargets, isEmpty);
      await finish(tester);
    });

    testWidgets('editing and deleting ask with Kotlin wording', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.wakeOnLan);
      await vm.saveWolTarget(name: 'nas', macAddress: 'aa:bb:cc:dd:ee:ff');
      await tester.pumpAndSettle();
      final target = vm.wolTargets.single;

      await tester.tap(find.byKey(ValueKey('network.wol.${target.id}.edit')));
      await tester.pumpAndSettle();
      expect(find.text('Edit WOL Pointer'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('network.wol.editor.notes')), 'rack 2');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('network.wol.editor.save')));
      expect(find.text('rack 2'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('network.wol.${target.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete "nas" from Wake-on-LAN targets?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('network.wol.deleteDialog.confirm')));
      await tester.pumpAndSettle();
      expect(vm.wolTargets, isEmpty);
      await finish(tester);
    });
  });

  group('DNS', () {
    testWidgets('lists the records as Kotlin cards', (tester) async {
      final probe = FakeProbe()..dnsResponses = {fallbackResolvers.first: aRecordResponse()};
      await pump(tester, probe);
      await goTo(tester, NetworkTab.dnsLookup);

      await tester.enterText(find.byKey(const ValueKey('network.dns.target')), 'example.com');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('network.dns.run')));

      expect(find.text('Value: 93.184.216.34'), findsOneWidget);
      expect(find.text('TTL: 300'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an unreachable resolver is reported, not silently empty', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.dnsLookup);
      await tester.enterText(find.byKey(const ValueKey('network.dns.target')), 'example.com');
      await tester.pump();
      await tapVisible(tester, find.byKey(const ValueKey('network.dns.run')));

      expect(find.byKey(const ValueKey('network.error')), findsOneWidget);
      await finish(tester);
    });
  });

  group('tunnels', () {
    testWidgets('without a forwarder the tab says so rather than offering dead switches', (
      tester,
    ) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.tunnels);
      expect(find.byKey(const ValueKey('network.tunnels.unavailable')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('with no hosts there is nothing to add a tunnel over', (tester) async {
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      expect(find.text('Add an SSH host first.'), findsOneWidget);
      final add = find.byKey(const ValueKey('network.tunnels.add'));
      expect(tester.widget<ButtonStyleButton>(add).onPressed, isNull);
      await finish(tester);
    });

    testWidgets('a saved tunnel is listed with Kotlin\'s summary', (tester) async {
      final serverId = await repo.insertServer(host(name: 'bastion'));
      await repo.insertPortForward(
        PortForwardsCompanion.insert(
          serverId: serverId,
          name: 'db',
          bindPort: 5433,
          destHost: const Value('db.internal'),
          destPort: const Value(5432),
        ),
      );
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);

      expect(find.text('db'), findsOneWidget);
      expect(find.text('-L 127.0.0.1:5433 → db.internal:5432'), findsOneWidget);
      expect(find.text('via bastion'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the editor keeps Save off until the ports are valid', (tester) async {
      await repo.insertServer(host(name: 'bastion'));
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      await tester.tap(find.byKey(const ValueKey('network.tunnels.add')));
      await tester.pumpAndSettle();
      expect(find.text('New tunnel'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.name')), 'web');
      await tester.pump();
      final save = find.byKey(const ValueKey('tunnelEditor.save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.bindPort')), '8080');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.destHost')), 'web.internal');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.destPort')), '80');
      await tester.pump();
      await tapVisible(tester, save);

      final saved = (await repo.getAllPortForwards()).single;
      expect(saved.bindPort, 8080);
      expect(saved.destHost, 'web.internal');
      await finish(tester);
    });

    testWidgets('a dynamic forward is not asked for a destination', (tester) async {
      await repo.insertServer(host(name: 'bastion'));
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      await tester.tap(find.byKey(const ValueKey('network.tunnels.add')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('tunnelEditor.kind.menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dynamic SOCKS (-D)').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tunnelEditor.destHost')), findsNothing);
      expect(find.textContaining('Opens a SOCKS5 proxy'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('deleting asks first with Kotlin wording', (tester) async {
      final serverId = await repo.insertServer(host(name: 'bastion'));
      await repo.insertPortForward(
        PortForwardsCompanion.insert(serverId: serverId, name: 'db', bindPort: 5433),
      );
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      final pf = vm.portForwards.single;

      await tester.tap(find.byKey(ValueKey('network.tunnel.${pf.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete "db"?'), findsOneWidget);
      expect(find.text("Remove this saved tunnel? If it's running it will be stopped."), findsOne);
      await tester.tap(find.byKey(const ValueKey('network.tunnel.deleteDialog.confirm')));
      await tester.pumpAndSettle();
      expect(vm.portForwards, isEmpty);
      await finish(tester);
    });
  });
}
