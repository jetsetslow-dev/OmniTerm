import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/servers/servers_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/servers_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late ServersViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    vm = ServersViewModel(app);
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await db.close();
  });

  Server server({
    required String name,
    String host = '10.0.0.1',
    String? group,
    String status = 'offline',
    String authStatus = 'unknown',
  }) => Server(
    id: 0,
    name: name,
    host: host,
    port: 22,
    username: 'root',
    groupName: group,
    serverColor: 'Default',
    authType: 'password',
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
    authStatus: authStatus,
  );

  Future<void> pump(WidgetTester tester) async {
    await app.start();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ServersViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: ServersScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty fleet shows the "no servers yet" state', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('servers.empty')), findsOneWidget);
    expect(find.text('No servers yet'), findsOneWidget);
  });

  testWidgets('hosts render as cards with their user@host line', (tester) async {
    await repo.insertServer(server(name: 'nas', host: '10.0.0.2'));
    await pump(tester);

    expect(find.text('nas'), findsOneWidget);
    expect(find.text('root@10.0.0.2'), findsOneWidget);
    expect(find.byKey(const ValueKey('servers.list')), findsOneWidget);
  });

  testWidgets('a failed automatic check keeps an explicit SSH anyway action', (tester) async {
    await repo.insertServer(server(name: 'nas', status: 'offline'));
    await pump(tester);

    expect(find.text('AUTOMATIC SSH CHECK FAILED'), findsOneWidget);
    expect(find.text('SSH ANYWAY'), findsOneWidget);
    expect(find.textContaining('No TCP route'), findsNothing);
  });

  testWidgets('the summary banner counts total, online and offline', (tester) async {
    await repo.insertServer(server(name: 'a', status: 'online'));
    await repo.insertServer(server(name: 'b', status: 'offline'));
    await repo.insertServer(server(name: 'c', status: 'online'));
    await pump(tester);

    final summary = find.byKey(const ValueKey('servers.summary'));
    expect(summary, findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('2')), findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('1')), findsWidgets);
  });

  testWidgets('typing in the search box filters the list', (tester) async {
    await repo.insertServer(server(name: 'web-prod'));
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('servers.search')), 'web');
    await tester.pumpAndSettle();

    expect(find.text('web-prod'), findsOneWidget);
    expect(find.text('nas'), findsNothing);
  });

  testWidgets('a search matching nothing shows the filter empty state, not "no servers"', (
    tester,
  ) async {
    // The same blank screen for both leaves the user thinking their fleet vanished.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('servers.search')), 'zzzz');
    await tester.pumpAndSettle();

    expect(find.text('No hosts match your filter'), findsOneWidget);
    expect(find.text('No servers yet'), findsNothing);
  });

  testWidgets('the clear button appears only with text and resets the filter', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);

    expect(find.byKey(const ValueKey('servers.search.clear')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('servers.search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('servers.search.clear')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('servers.search.clear')));
    await tester.pumpAndSettle();
    expect(find.text('nas'), findsOneWidget);
  });

  testWidgets('group chips appear only when groups exist and filter on tap', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    // One chip ("All") is not a filter bar worth showing.
    expect(find.byKey(const ValueKey('servers.groupChips')), findsNothing);

    await repo.insertServer(server(name: 'web', group: 'prod'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('servers.groupChips')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('servers.groupChip.prod')));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget);
    expect(find.text('nas'), findsNothing);
  });

  testWidgets('tapping a card selects that host', (tester) async {
    await repo.insertServer(server(name: 'a'));
    final bId = await repo.insertServer(server(name: 'b'));
    await pump(tester);

    await tester.tap(find.byKey(ValueKey('servers.card.$bId')));
    await tester.pumpAndSettle();

    expect(app.selectedServerId, bId);
  });

  testWidgets('multi-select shows checkboxes and ticking does not change the selected host', (
    tester,
  ) async {
    final id = await repo.insertServer(server(name: 'a'));
    await pump(tester);
    final selectedBefore = app.selectedServerId;

    await tester.tap(find.byKey(const ValueKey('servers.multiSelect.toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('servers.card.$id.check')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('servers.card.$id')));
    await tester.pumpAndSettle();

    expect(vm.selectedServerIdsForBulk, [id]);
    expect(
      app.selectedServerId,
      selectedBefore,
      reason: 'ticking a row in multi-select must not also switch the active host',
    );
  });

  testWidgets('leaving multi-select hides the checkboxes and drops the ticks', (tester) async {
    final id = await repo.insertServer(server(name: 'a'));
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('servers.multiSelect.toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('servers.card.$id')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('servers.multiSelect.toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('servers.card.$id.check')), findsNothing);
    expect(vm.selectedServerIdsForBulk, isEmpty);
  });

  testWidgets('hide-sensitive-info masks the address', (tester) async {
    await repo.insertServer(server(name: 'nas', host: '10.0.0.2'));
    await pump(tester);
    expect(find.text('root@10.0.0.2'), findsOneWidget);

    HostDisplay.instance.hideSensitiveInfo = true;
    await tester.pumpAndSettle();

    expect(
      find.text('root@10.0.0.2'),
      findsNothing,
      reason: 'the whole point is that a screenshot cannot leak the address',
    );
    expect(find.text('root@nas'), findsOneWidget);
  });

  testWidgets('an auth failure is distinguished from being offline', (tester) async {
    // Calling a host with rejected credentials "online" sends the user hunting the wrong fault.
    await repo.insertServer(server(name: 'nas', status: 'online', authStatus: 'failed'));
    await pump(tester);

    final semantics = tester.getSemantics(find.byKey(const ValueKey('servers.card.1')));
    expect(semantics.label, contains('authentication failed'));
  });
}
