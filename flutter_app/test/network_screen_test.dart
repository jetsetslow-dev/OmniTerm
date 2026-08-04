import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
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

  Future<void> pump(WidgetTester tester, FakeProbe probe) async {
    await app.start();
    vm = NetworkViewModel(app, probe: probe);
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

  Future<void> goTo(WidgetTester tester, NetworkTab tab) async {
    await tester.tap(find.byKey(ValueKey('network.tab.${tab.name}')));
    await tester.pumpAndSettle();
  }

  testWidgets('every tab is present and reachable', (tester) async {
    await pump(tester, FakeProbe());

    for (final tab in NetworkTab.values) {
      expect(find.byKey(ValueKey('network.tab.${tab.name}')), findsOneWidget);
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
}
