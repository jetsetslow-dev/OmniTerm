import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_tunnel_manager.dart';
import 'package:omniterm/domain/network_tools.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/network_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/network_view_model.dart';
import 'package:provider/provider.dart';

import 'network_view_model_test.dart' show FakeProbe, aRecordResponse;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late NetworkViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, FakeProbe probe, {SshTunnelManager? tunnels}) async {
    await app.start();
    vm = NetworkViewModel(app, probe: probe, tunnels: tunnels);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<NetworkViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: NetworkScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// See MIGRATION.md: cancelling a drift `watch` subscription schedules zero-duration timers.
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

  testWidgets('every tab is present and reachable', (tester) async {
    await pump(tester, FakeProbe());

    for (final tab in NetworkTab.values) {
      // Scrolled to, because a chip off the end of the strip is not built at all.
      await tester.dragUntilVisible(
        find.byKey(ValueKey('network.tab.${tab.name}')),
        find.byKey(const ValueKey('network.tabs')),
        const Offset(-120, 0),
      );
      await tester.tap(find.byKey(ValueKey('network.tab.${tab.name}')));
      await tester.pumpAndSettle();
      expect(vm.activeTab, tab);
    }
    for (final (tab, probeKey) in [
      (NetworkTab.wakeOnLan, 'network.wol.empty'),
      (NetworkTab.ping, 'network.ping.list'),
      (NetworkTab.portScan, 'network.portScan.empty'),
      (NetworkTab.dnsLookup, 'network.dns.empty'),
      (NetworkTab.hostScan, 'network.scan.empty'),
    ]) {
      await goTo(tester, tab);
      expect(find.byKey(ValueKey(probeKey)), findsOneWidget, reason: '${tab.name} did not render');
    }
    await finish(tester);
  });

  group('host scan', () {
    testWidgets('the subnet is prefilled from the device', (tester) async {
      await pump(tester, FakeProbe(local: '10.0.5.77'));
      expect(vm.subnetPrefix, '10.0.5');
      await finish(tester);
    });

    testWidgets('found hosts are listed with their ports and name', (tester) async {
      await pump(
        tester,
        FakeProbe(
          open: {'192.168.1.5:22', '192.168.1.5:80'},
          names: {'192.168.1.5': 'nas.local'},
          local: '192.168.1.42',
        ),
      );

      await tester.tap(find.byKey(const ValueKey('network.scan.run')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('network.scan.192.168.1.5')), findsOneWidget);
      expect(find.text('nas.local'), findsOneWidget);
      expect(find.textContaining('SSH, HTTP'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a result offers the tools that take an address', (tester) async {
      // A scan result is not yet bound to a tool — the user has just found a device.
      await pump(tester, FakeProbe(open: {'192.168.1.5:22'}, local: '192.168.1.42'));
      await tester.tap(find.byKey(const ValueKey('network.scan.run')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('network.scan.192.168.1.5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('network.scan.action.portScan')));
      await tester.pumpAndSettle();

      expect(vm.activeTab, NetworkTab.portScan);
      expect(vm.portScanTarget, '192.168.1.5');
      expect(find.byKey(const ValueKey('network.portScan.target')), findsOneWidget);
      await finish(tester);
    });
  });

  group('wake on LAN', () {
    testWidgets('the empty state names the prerequisite', (tester) async {
      // Wake-on-LAN silently does nothing when the machine has it disabled, so saying so up front
      // beats letting it be discovered.
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.wakeOnLan);
      expect(find.textContaining('enabled in its BIOS'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a target is created and can be woken', (tester) async {
      final probe = FakeProbe();
      await pump(tester, probe);
      await goTo(tester, NetworkTab.wakeOnLan);

      await tester.tap(find.byKey(const ValueKey('network.wol.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('network.wol.name')), 'nas');
      await tester.enterText(find.byKey(const ValueKey('network.wol.mac')), 'aa:bb:cc:dd:ee:ff');
      await tester.enterText(find.byKey(const ValueKey('network.wol.ip')), '192.168.4.20');
      await tester.tap(find.byKey(const ValueKey('network.wol.save')));
      await tester.pumpAndSettle();

      expect(find.text('nas'), findsOneWidget);
      expect(find.textContaining('192.168.4.255:9'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('network.wol.${vm.wolTargets.single.id}.wake')));
      await tester.pumpAndSettle();

      expect(probe.sentPackets, hasLength(1));
      expect(find.textContaining('Magic packet sent'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a bad MAC is refused in the sheet', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.wakeOnLan);

      await tester.tap(find.byKey(const ValueKey('network.wol.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('network.wol.name')), 'nas');
      await tester.enterText(find.byKey(const ValueKey('network.wol.mac')), 'nope');
      await tester.tap(find.byKey(const ValueKey('network.wol.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('network.wol.error')), findsOneWidget);
      expect(vm.wolTargets, isEmpty);
      await finish(tester);
    });
  });

  group('ping', () {
    testWidgets('says plainly that it is a TCP connect, not ICMP', (tester) async {
      // A host that is up with nothing on the port reads as down; the user needs that to read the
      // result correctly.
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.ping);
      expect(find.textContaining('ICMP needs privileges'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('reports each attempt and a summary', (tester) async {
      await pump(tester, FakeProbe(open: {'10.0.0.1:22'}));
      await goTo(tester, NetworkTab.ping);

      await tester.enterText(find.byKey(const ValueKey('network.ping.target')), '10.0.0.1');
      await tester.tap(find.byKey(const ValueKey('network.ping.run')));
      await tester.pumpAndSettle();

      expect(find.textContaining('100% replied'), findsOneWidget);
      expect(find.textContaining('seq 1: 12 ms'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('no reply is a result, not an error', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.ping);

      await tester.enterText(find.byKey(const ValueKey('network.ping.target')), '10.0.0.99');
      await tester.tap(find.byKey(const ValueKey('network.ping.run')));
      await tester.pumpAndSettle();

      expect(find.textContaining('0% replied'), findsOneWidget);
      expect(find.textContaining('no reply'), findsWidgets);
      expect(find.byKey(const ValueKey('network.error')), findsNothing);
      await finish(tester);
    });
  });

  group('port scan', () {
    testWidgets('lists only the open ports, with their service names', (tester) async {
      // A list of two dozen closed ports buries the answer.
      await pump(tester, FakeProbe(open: {'10.0.0.1:22', '10.0.0.1:443'}));
      await goTo(tester, NetworkTab.portScan);

      await tester.enterText(find.byKey(const ValueKey('network.portScan.target')), '10.0.0.1');
      await tester.enterText(find.byKey(const ValueKey('network.portScan.ports')), '22,80,443');
      await tester.tap(find.byKey(const ValueKey('network.portScan.run')));
      await tester.pumpAndSettle();

      expect(find.text('2 open of 3 probed'), findsOneWidget);
      expect(find.text('22 · SSH'), findsOneWidget);
      expect(find.text('443 · HTTPS'), findsOneWidget);
      expect(find.textContaining('80 ·'), findsNothing);
      await finish(tester);
    });

    testWidgets('an unusable port spec is reported with an example', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.portScan);

      await tester.enterText(find.byKey(const ValueKey('network.portScan.target')), '10.0.0.1');
      await tester.enterText(find.byKey(const ValueKey('network.portScan.ports')), 'nonsense');
      await tester.tap(find.byKey(const ValueKey('network.portScan.run')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('network.error')), findsOneWidget);
      expect(find.textContaining('22,80,443'), findsWidgets);
      await finish(tester);
    });
  });

  group('DNS', () {
    testWidgets('lists the records it resolved', (tester) async {
      final probe = FakeProbe()..dnsResponses = {fallbackResolvers.first: aRecordResponse()};
      await pump(tester, probe);
      await goTo(tester, NetworkTab.dnsLookup);

      await tester.enterText(find.byKey(const ValueKey('network.dns.target')), 'example.com');
      await tester.tap(find.byKey(const ValueKey('network.dns.run')));
      await tester.pumpAndSettle();

      expect(find.text('93.184.216.34'), findsOneWidget);
      expect(find.text('A'), findsWidgets);
      expect(find.textContaining('TTL 300'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an unreachable resolver is reported, not silently empty', (tester) async {
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.dnsLookup);

      await tester.enterText(find.byKey(const ValueKey('network.dns.target')), 'example.com');
      await tester.tap(find.byKey(const ValueKey('network.dns.run')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('network.error')), findsOneWidget);
      expect(find.textContaining('Could not reach a DNS resolver'), findsOneWidget);
      await finish(tester);
    });
  });

  group('tunnels', () {
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

    testWidgets('without a forwarder the tab says so rather than offering dead switches', (
      tester,
    ) async {
      // Convention 4: an absent dependency disables the feature and explains itself.
      await repo.insertServer(host(name: 'nas'));
      await pump(tester, FakeProbe());
      await goTo(tester, NetworkTab.tunnels);

      expect(find.byKey(const ValueKey('tunnels.unavailable')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('with no hosts there is nothing to add a tunnel over', (tester) async {
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);

      expect(find.byKey(const ValueKey('tunnels.noHosts')), findsOneWidget);
      final add = tester.widget<FilledButton>(find.byKey(const ValueKey('tunnels.add')));
      expect(add.onPressed, isNull, reason: 'a tunnel runs over a host');
      await finish(tester);
    });

    testWidgets('a saved tunnel is listed with what it actually does', (tester) async {
      await repo.insertServer(host(name: 'nas'));
      await repo.insertPortForward(
        PortForwardsCompanion.insert(
          serverId: 1,
          name: 'web',
          kind: const Value('local'),
          bindHost: const Value('127.0.0.1'),
          bindPort: 8080,
          destHost: const Value('10.0.0.5'),
          destPort: const Value(80),
        ),
      );
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      await tester.pumpAndSettle();

      expect(find.text('web'), findsOneWidget);
      expect(find.text('-L 127.0.0.1:8080 → 10.0.0.5:80'), findsOneWidget);
      expect(find.text('via nas'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a tunnel whose host was deleted says so instead of looking fine', (tester) async {
      // The row would otherwise read normally and fail only when someone flipped the switch.
      // Another host has to exist, or the tab shows "add a host first" instead of the list.
      await repo.insertServer(host(name: 'other'));
      await repo.insertPortForward(
        PortForwardsCompanion.insert(serverId: 99, name: 'orphan', bindPort: 9999),
      );
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      await tester.pumpAndSettle();

      expect(find.text('host no longer exists'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the editor refuses a port nobody typed', (tester) async {
      await repo.insertServer(host(name: 'nas'));
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);

      await tester.tap(find.byKey(const ValueKey('tunnels.add')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.name')), 'web');
      await tester.pumpAndSettle();

      var save = tester.widget<FilledButton>(find.byKey(const ValueKey('tunnelEditor.save')));
      expect(save.onPressed, isNull, reason: 'no bind port has been given');
      expect(find.byKey(const ValueKey('tunnelEditor.error')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.bindPort')), '8080');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.destHost')), '10.0.0.5');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.destPort')), '80');
      await tester.pumpAndSettle();

      save = tester.widget<FilledButton>(find.byKey(const ValueKey('tunnelEditor.save')));
      expect(save.onPressed, isNotNull);

      await tester.ensureVisible(find.byKey(const ValueKey('tunnelEditor.save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tunnelEditor.save')));
      await tester.pumpAndSettle();

      final saved = await repo.getAllPortForwards();
      expect(saved.single.name, 'web');
      expect(saved.single.bindPort, 8080);
      await finish(tester);
    });

    testWidgets('a dynamic forward is not asked for a destination', (tester) async {
      await repo.insertServer(host(name: 'nas'));
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);

      await tester.tap(find.byKey(const ValueKey('tunnels.add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tunnelEditor.destHost')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tunnelEditor.kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('-D  SOCKS5 proxy').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tunnelEditor.destHost')),
        findsNothing,
        reason: 'SOCKS decides its destination per connection',
      );
      await finish(tester);
    });

    testWidgets('auto-start is offered, saved, and honest about its lifetime', (tester) async {
      // The column existed from the first schema and nothing set it, so a tunnel could never be
      // marked to start on its own — the field was storage with no way in.
      await repo.insertServer(host(name: 'nas'));
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);

      await tester.tap(find.byKey(const ValueKey('tunnels.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.name')), 'web');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.bindPort')), '8080');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.destHost')), '10.0.0.5');
      await tester.enterText(find.byKey(const ValueKey('tunnelEditor.destPort')), '80');
      await tester.pumpAndSettle();

      // A tunnel is not a system service, and a user who expected it to outlive the app would be
      // wrong in a way that matters.
      expect(find.textContaining('closing OmniTerm takes the tunnel down'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('tunnelEditor.autoStart')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tunnelEditor.autoStart')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('tunnelEditor.save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tunnelEditor.save')));
      await tester.pumpAndSettle();

      expect((await repo.getAllPortForwards()).single.autoStart, isTrue);
      await finish(tester);
    });

    testWidgets('each mode explains itself, not just its flag', (tester) async {
      await repo.insertServer(host(name: 'nas'));
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);

      await tester.tap(find.byKey(const ValueKey('tunnels.add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('This device listens'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tunnelEditor.kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('-D  SOCKS5 proxy').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('SOCKS5 proxy on the bind address'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('deleting asks first and says a running tunnel would be stopped', (tester) async {
      await repo.insertServer(host(name: 'nas'));
      await repo.insertPortForward(
        PortForwardsCompanion.insert(serverId: 1, name: 'web', bindPort: 8080),
      );
      await pump(tester, FakeProbe(), tunnels: SshTunnelManager((_) async => throw 'never'));
      await goTo(tester, NetworkTab.tunnels);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('tunnels.card.1.delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('it will be stopped'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tunnels.delete.cancel')));
      await tester.pumpAndSettle();
      expect(await repo.getAllPortForwards(), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('tunnels.card.1.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tunnels.delete.confirm')));
      await tester.pumpAndSettle();
      expect(await repo.getAllPortForwards(), isEmpty);
      await finish(tester);
    });
  });
}
