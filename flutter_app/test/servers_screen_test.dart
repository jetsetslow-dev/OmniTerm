import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/l10n/app_localizations.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/servers/servers_screen.dart';
import 'package:omniterm/ui/theme/colors.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/servers_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

/// Answers no TCP ping, so a probe reaches an offline verdict without touching the network.
class _UnreachableProbe implements NetworkProbe {
  @override
  Future<Duration?> tcpPing(String host, int port, {Duration timeout = Duration.zero}) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  Future<void> pump(WidgetTester tester, {HostStatusProbe? hostProbe, bool settle = true}) async {
    await app.start();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ServersViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: Scaffold(body: ServersScreen(hostProbe: hostProbe)),
        ),
      ),
    );
    // The "Checking host…" spinner never settles.
    settle ? await tester.pumpAndSettle() : await tester.pump();
  }

  Color? dotColor(WidgetTester tester) {
    final dot = tester.widget<Container>(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
            w.constraints?.maxWidth == 8,
      ),
    );
    return (dot.decoration! as BoxDecoration).color;
  }

  testWidgets('an online row with no verified metrics does not advertise perfect health', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'unmeasured', status: 'online', authStatus: 'ok'));
    await pump(tester);
    expect(find.text('100'), findsNothing);
    expect(find.text('—'), findsWidgets);
    expect(find.text('Metrics unavailable · Refresh to retry'), findsOneWidget);
  });

  // Bulk delete removes host connections *and their saved credentials*, and the screen says it
  // "cannot be undone here". `servers_view_model_test` covers `deleteSelectedServers()` directly,
  // which bypasses the dialog entirely — so nothing covered the wiring: that the dialog appears at
  // all, that Cancel really cancels, and that Delete removes only the selection. A confirm wired to
  // the wrong branch would have passed every existing test. The Cancel button had no key either.
  testWidgets('cancelling a bulk delete keeps every host', (tester) async {
    final nas = await repo.insertServer(server(name: 'nas'));
    final web = await repo.insertServer(server(name: 'web-prod'));
    await pump(tester);
    vm.isMultiSelectMode = true;
    vm.toggleBulkSelection(nas);
    vm.toggleBulkSelection(web);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('servers.bulk.delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('servers.bulk.deleteConfirm')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('servers.bulk.deleteCancel')));
    await tester.pumpAndSettle();

    // The effect, not the dialog: backing out of a destructive confirmation must leave the data
    // alone, which is the only thing the user actually cares about here.
    expect(app.servers, hasLength(2), reason: 'cancelling must not delete anything');
    expect(find.text('nas'), findsOneWidget);
    expect(find.text('web-prod'), findsOneWidget);
  });

  testWidgets('confirming a bulk delete removes exactly the selected hosts', (tester) async {
    final nas = await repo.insertServer(server(name: 'nas'));
    await repo.insertServer(server(name: 'web-prod'));
    await pump(tester);
    vm.isMultiSelectMode = true;
    vm.toggleBulkSelection(nas);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('servers.bulk.delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('servers.bulk.deleteConfirm')));
    await tester.pumpAndSettle();

    // "Exactly" is the assertion that matters: a bulk action that deletes the selection plus
    // something else, or the whole list, is the expensive failure this dialog exists to prevent.
    expect(app.servers, hasLength(1));
    expect(find.text('nas'), findsNothing);
    expect(find.text('web-prod'), findsOneWidget, reason: 'an unselected host must survive');
  });

  testWidgets('an empty fleet shows Kotlin\'s first-run checklist and Add Host Server', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('servers.empty')), findsOneWidget);
    expect(find.text('Connect your first server'), findsOneWidget);
    expect(find.textContaining('sudo apt install openssh-server'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('servers.empty.add')));
    await tester.pumpAndSettle();
    expect(find.text('Add Linux Remote Host'), findsOneWidget);
  });

  for (final filtered in [false, true]) {
    testWidgets('the ${filtered ? "filtered" : "empty"} fleet fits behind the keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (filtered) {
        await repo.insertServer(server(name: 'nas'));
      }
      await pump(tester);
      if (filtered) {
        await tester.enterText(find.byKey(const ValueKey('servers.search')), 'no match');
        await tester.pumpAndSettle();
      }
      final empty = find.byKey(const ValueKey('servers.empty'));
      // The actual Android save flow leaves this underlying viewport only 110 dp tall.
      final originalHeight = tester.getSize(empty).height;
      expect(originalHeight, greaterThan(110));
      tester.view.viewInsets = FakeViewPadding(bottom: originalHeight - 110);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final message = find.text(filtered ? 'No servers found' : 'Connect your first server');
      await tester.ensureVisible(message);
      await tester.pumpAndSettle();
      expect(message.hitTestable(), findsOneWidget);
    });
  }

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

  // Kotlin's card reads `probedServerIds`: a host's stored status is `offline` until something has
  // looked at it, so a just-added host showed a failed check before its first probe had even run.
  testWidgets('an unprobed host reads as being checked, then as failed once probed', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas', status: 'offline'));
    final probe = HostStatusProbe(repo, probe: _UnreachableProbe());
    addTearDown(probe.dispose);
    await pump(tester, hostProbe: probe, settle: false);

    expect(find.text('Checking host…'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('AUTOMATIC SSH CHECK FAILED'), findsNothing);
    expect(dotColor(tester), OmniColors.red);

    final probing = probe.probeOne((await repo.getAllServers()).single);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await probing;
    await tester.pumpAndSettle();

    expect(find.text('Checking host…'), findsNothing);
    expect(find.text('Offline'), findsWidgets);
    expect(find.text('AUTOMATIC SSH CHECK FAILED'), findsOneWidget);
  });

  testWidgets('a host being checked has the amber status dot Kotlin uses', (tester) async {
    await repo.insertServer(server(name: 'nas', status: 'connecting'));
    await pump(tester, settle: false);
    expect(dotColor(tester), OmniColors.amber);
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

    expect(find.text('No servers found'), findsOneWidget);
    expect(find.text('Connect your first server'), findsNothing);
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

  testWidgets('group chips always lead with All, as Kotlin, and filter on tap', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    expect(find.byKey(const ValueKey('servers.groupChip.All')), findsOneWidget);

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
