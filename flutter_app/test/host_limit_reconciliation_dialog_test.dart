import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/l10n/app_localizations.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/shell_state.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/servers_view_model.dart';
import 'package:omniterm/ui/widgets/host_limit_reconciliation_dialog.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

/// Counts the tmux sessions in [tmuxByHost] and records each keep instead of deleting anything.
/// The deletes themselves are covered in `shell_view_model_test.dart`.
class _Hosts extends ServersViewModel {
  _Hosts(super.app, this.tmuxByHost);

  final Map<int, int> tmuxByHost;
  final List<(int, bool)> kept = [];

  @override
  int tmuxSessionCount(Set<int> serverIds) =>
      serverIds.fold(0, (sum, id) => sum + (tmuxByHost[id] ?? 0));

  @override
  Future<int> reconcileHostLimit(Set<int> keepIds, {bool endTmuxSessions = false}) async {
    kept.add((keepIds.single, endTmuxSessions));
    return servers.length - 1;
  }
}

/// The free plan's "Choose host to keep" dialog, as Kotlin's `HostLimitReconciliationDialog`.
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late ShellState shell;
  late NavigationController navigation;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    shell = ShellState()
      ..updateLicenseEntitlement(enabled: true, resolved: true, unlocked: false, adsRemoved: false);
    // Somewhere other than Hosts, so returning there is something the dialog did.
    navigation = NavigationController()..navigateTo(Screen.monitor);
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server(String name) => Server(
    id: 0,
    name: name,
    host: '$name.lan',
    port: 2222,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    sudoPassword: '',
    notes: '',
    keepAlive: 30,
    sshCompression: false,
    persistentSession: true,
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

  Future<_Hosts> pump(WidgetTester tester, Map<String, int> tmuxByName) async {
    final ids = {for (final name in tmuxByName.keys) name: await repo.insertServer(server(name))};
    await app.start();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final hosts = _Hosts(app, {
      for (final entry in tmuxByName.entries) ids[entry.key]!: entry.value,
    });
    addTearDown(hosts.dispose);
    shell.reconcileHostLimit(app.servers.length);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ServersViewModel>.value(value: hosts),
          ChangeNotifierProvider<ShellState>.value(value: shell),
          ChangeNotifierProvider<NavigationController>.value(value: navigation),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HostLimitReconciliationDialog(reason: '')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return hosts;
  }

  testWidgets('keeps the picked host without touching tmux when none is running', (tester) async {
    final hosts = await pump(tester, {'alpha': 0, 'bravo': 0});

    expect(find.text('Choose host to keep'), findsOneWidget);
    expect(find.text('The free Play Store build supports one saved host.'), findsOneWidget);
    expect(find.text('root@bravo.lan:2222'), findsOneWidget);
    expect(find.byKey(const ValueKey('license.hostReconciliation.endTmux')), findsNothing);

    final bravo = app.servers.firstWhere((s) => s.name == 'bravo').id;
    await tester.tap(find.byKey(ValueKey('license.hostReconciliation.$bravo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('license.hostReconciliation.keep')));
    await tester.pumpAndSettle();

    expect(hosts.kept, [(bravo, false)]);
    expect(navigation.currentScreen, Screen.servers);
    expect(shell.hostLimitReconciliationRequired, isFalse);
  });

  testWidgets('offers to end the tmux sessions on the hosts it removes', (tester) async {
    final hosts = await pump(tester, {'alpha': 1, 'bravo': 2, 'charlie': 0});
    final bravo = app.servers.firstWhere((s) => s.name == 'bravo').id;

    // Keeping alpha, the first, removes bravo's two.
    expect(find.text('Also end the 2 tmux sessions running on the removed hosts'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('license.hostReconciliation.$bravo')));
    await tester.pumpAndSettle();
    expect(find.text('Also end the tmux session running on a removed host'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('license.hostReconciliation.endTmux')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('license.hostReconciliation.keep')));
    await tester.pumpAndSettle();

    expect(hosts.kept, [(bravo, true)]);
  });

  testWidgets('a tick on an option that went away ends nothing', (tester) async {
    final hosts = await pump(tester, {'alpha': 0, 'bravo': 1});
    final bravo = app.servers.firstWhere((s) => s.name == 'bravo').id;

    await tester.tap(find.byKey(const ValueKey('license.hostReconciliation.endTmux')));
    await tester.pumpAndSettle();
    // Keeping bravo leaves only alpha, which has no tmux session to end.
    await tester.tap(find.byKey(ValueKey('license.hostReconciliation.$bravo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('license.hostReconciliation.endTmux')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('license.hostReconciliation.keep')));
    await tester.pumpAndSettle();

    expect(hosts.kept, [(bravo, false)]);
  });
}
