import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:omniterm/ui/view_model/network_view_model.dart';
import 'package:omniterm/ui/view_model/servers_view_model.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:provider/provider.dart';

import 'network_view_model_test.dart' show FakeDeviceCommands;
import 'support/fake_secure_storage.dart';

/// Answers no TCP ping, so a probe reaches an offline verdict without touching the network.
class _UnreachableProbe implements NetworkProbe {
  @override
  Future<Duration?> tcpPing(String host, int port, {Duration timeout = Duration.zero}) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Reports [tmux] sessions on any set of hosts and records each delete instead of doing it, so the
/// dialogs can be checked without a shell. The deletes themselves are covered in
/// `shell_view_model_test.dart`.
class _TmuxHosts extends ServersViewModel {
  _TmuxHosts(super.app, this.tmux);

  final int tmux;

  /// The ids each delete was asked for, sorted and comma-joined, and whether to end their tmux
  /// sessions.
  final List<(String, bool)> deletes = [];

  @override
  int tmuxSessionCount(Set<int> serverIds) => tmux;

  @override
  Future<void> deleteServer(int serverId, {bool endTmuxSessions = false}) async =>
      deletes.add(('$serverId', endTmuxSessions));

  @override
  Future<void> deleteSelectedServers({bool endTmuxSessions = false}) async =>
      deletes.add((([...selectedServerIdsForBulk]..sort()).join(','), endTmuxSessions));
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

  Future<void> pump(
    WidgetTester tester, {
    HostStatusProbe? hostProbe,
    NetworkViewModel? network,
    ShellViewModel? shell,
    bool settle = true,
  }) async {
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
          home: Scaffold(
            body: ServersScreen(hostProbe: hostProbe, network: network, shell: shell),
          ),
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
    // As Kotlin: a waiting line rather than a row of empty gauges.
    expect(find.text('Waiting for verified metrics…'), findsOneWidget);
    expect(find.text('CPU'), findsNothing);
  });

  testWidgets('an online row without metrics says why when there is a reason', (tester) async {
    final id = await repo.insertServer(server(name: 'moved', status: 'online', authStatus: 'ok'));
    app.setMetricsError(id, 'Host address changed. Waiting for current metrics.');
    await pump(tester);
    expect(find.text('Host address changed. Waiting for current metrics.'), findsOneWidget);
    expect(find.text('Waiting for verified metrics…'), findsNothing);
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
    expect(find.byKey(const ValueKey('servers.bulk.delete.confirm')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('servers.bulk.delete.cancel')));
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
    await tester.tap(find.byKey(const ValueKey('servers.bulk.delete.confirm')));
    await tester.pumpAndSettle();

    // "Exactly" is the assertion that matters: a bulk action that deletes the selection plus
    // something else, or the whole list, is the expensive failure this dialog exists to prevent.
    expect(app.servers, hasLength(1));
    expect(find.text('nas'), findsNothing);
    expect(find.text('web-prod'), findsOneWidget, reason: 'an unselected host must survive');
  });

  group('the delete dialog', () {
    // Kotlin offers to end the hosts' tmux sessions only when there are some, since the dialog
    // otherwise promises the remote machine is left alone.
    Future<_TmuxHosts> withTmux(int tmux) async {
      vm.dispose();
      final hosts = _TmuxHosts(app, tmux);
      vm = hosts;
      return hosts;
    }

    Future<int> openDelete(WidgetTester tester) async {
      final id = await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await tester.tap(find.byKey(ValueKey('servers.card.$id.actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('servers.action.delete')));
      await tester.pumpAndSettle();
      return id;
    }

    testWidgets('a host without tmux sessions is just deleted', (tester) async {
      final hosts = await withTmux(0);
      final id = await openDelete(tester);

      expect(find.text('Delete nas?'), findsOneWidget);
      expect(
        find.text(
          'Remove this host connection (and its saved credentials) from OmniTerm? This does not '
          'affect the remote machine, but cannot be undone here.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('servers.card.$id.delete.option')), findsNothing);
      await tester.tap(find.byKey(ValueKey('servers.card.$id.delete.confirm')));
      await tester.pumpAndSettle();

      expect(hosts.deletes, [('$id', false)]);
    });

    testWidgets('a host with tmux sessions offers to end them, unticked', (tester) async {
      final hosts = await withTmux(2);
      final id = await openDelete(tester);

      expect(find.text('Also end its 2 tmux sessions on the server'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('servers.card.$id.delete.option')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('servers.card.$id.delete.confirm')));
      await tester.pumpAndSettle();

      expect(hosts.deletes, [('$id', true)]);
    });

    testWidgets('cancelling deletes nothing, ticked or not', (tester) async {
      final hosts = await withTmux(1);
      final id = await openDelete(tester);

      expect(find.text('Also end its tmux session on the server'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('servers.card.$id.delete.option')));
      await tester.tap(find.byKey(ValueKey('servers.card.$id.delete.cancel')));
      await tester.pumpAndSettle();

      expect(hosts.deletes, isEmpty);
    });

    testWidgets('a bulk delete words the option for the removed hosts', (tester) async {
      final hosts = await withTmux(3);
      final nas = await repo.insertServer(server(name: 'nas'));
      final web = await repo.insertServer(server(name: 'web-prod'));
      await pump(tester);
      vm.isMultiSelectMode = true;
      vm.toggleBulkSelection(nas);
      vm.toggleBulkSelection(web);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('servers.bulk.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 hosts?'), findsOneWidget);
      expect(
        find.text(
          'Remove these host connections (and their saved credentials) from OmniTerm? This does '
          'not affect the remote machines, but cannot be undone here.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Also end the 3 tmux sessions running on the removed hosts'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('servers.bulk.delete.confirm')));
      await tester.pumpAndSettle();

      expect(hosts.deletes, [('$nas,$web', false)]);
    });
  });

  testWidgets('Attach existing tmux… is offered on hosts that can have tmux, while online', (
    tester,
  ) async {
    final shell = ShellViewModel(app);
    addTearDown(shell.dispose);
    final up = await repo.insertServer(server(name: 'nas', status: 'online'));
    final down = await repo.insertServer(server(name: 'old'));
    final windows = await repo.insertServer(server(name: 'win', status: 'online'));
    app.recordOsForServer(windows, 'Windows');
    await pump(tester, shell: shell);

    /// Whether the host's ⋮ menu has the entry, and whether it can be tapped; null when absent.
    Future<bool?> attachIn(int id) async {
      await tester.tap(find.byKey(ValueKey('servers.card.$id.actions')));
      await tester.pumpAndSettle();
      final found = find.byKey(const ValueKey('servers.action.attachTmux'));
      final enabled = found.evaluate().isEmpty
          ? null
          : tester.widget<SimpleDialogOption>(found).onPressed != null;
      if (enabled != null) expect(find.text('Attach existing tmux…'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      return enabled;
    }

    expect(await attachIn(up), isTrue);
    expect(await attachIn(down), isFalse, reason: 'listed only while it answers');
    expect(await attachIn(windows), isNull, reason: 'Windows has no tmux: absent, not refused');
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
    expect(find.text('SSH anyway'), findsOneWidget);
    expect(find.textContaining('No TCP route'), findsNothing);
  });

  NetworkViewModel network() {
    final network = NetworkViewModel(app, deviceCommands: FakeDeviceCommands())..watchWolTargets();
    addTearDown(network.dispose);
    return network;
  }

  testWidgets('an offline card offers WAKE for a wake target at its address, and PING', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas', host: '10.0.0.1'));
    await repo.insertServer(server(name: 'web', host: '10.0.0.2'));
    await repo.insertWolTarget(
      WolTargetsCompanion.insert(
        name: 'nas',
        macAddress: 'AA:BB:CC:DD:EE:FF',
        ipAddress: const Value('10.0.0.1'),
      ),
    );
    await pump(tester, network: network());

    final ids = {for (final s in app.servers) s.name: s.id};
    expect(find.byKey(ValueKey('servers.card.${ids['nas']}.wake')), findsOneWidget);
    expect(find.byKey(ValueKey('servers.card.${ids['web']}.wake')), findsNothing);
    expect(find.text('PING'), findsNWidgets(2));

    await tester.tap(find.byKey(ValueKey('servers.card.${ids['nas']}.wake')));
    await tester.pumpAndSettle();
    expect(find.text('Send wake packet?'), findsOneWidget);
    expect(
      find.text('Send a Wake-on-LAN magic packet to "nas" (AA:BB:CC:DD:EE:FF)?'),
      findsOneWidget,
    );
  });

  testWidgets('PING opens the host check and closing it stops and forgets the check', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas', host: '10.0.0.1'));
    final net = network();
    await pump(tester, network: net);

    await tester.tap(find.byKey(ValueKey('servers.card.${app.servers.single.id}.ping')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('hosts.check.dialog')), findsOneWidget);
    expect(find.text('Ping nas'), findsOneWidget);
    expect(find.textContaining('icmp_seq=1'), findsOneWidget);
    expect(find.byKey(const ValueKey('hosts.check.again')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hosts.check.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hosts.check.dialog')), findsNothing);
    expect(net.hostCheck, isNull);
  });

  testWidgets('an offline card says when the host was last seen', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await repo.insertServer(server(name: 'web', host: '10.0.0.2'));
    await app.start();
    final ids = {for (final s in await repo.getAllServers()) s.name: s.id};
    final now = DateTime.now().millisecondsSinceEpoch;
    app.noteSeen(ids['nas']!, now - 10000);
    app.noteSeen(ids['web']!, now - const Duration(minutes: 5, seconds: 10).inMilliseconds);
    await pump(tester);

    expect(find.text('Last seen just now'), findsOneWidget);
    expect(find.text('Last seen 5m ago'), findsOneWidget);
  });

  testWidgets('the sort menu reorders the hosts and remembers the choice', (tester) async {
    await repo.insertServer(server(name: 'alpha'));
    await repo.insertServer(server(name: 'bravo', status: 'online', authStatus: 'ok'));
    await pump(tester);
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('alpha'), lessThan(top('bravo')));

    await tester.tap(find.byKey(const ValueKey('servers.sort')));
    await tester.pumpAndSettle();
    expect(find.text('Latency (fastest first)'), findsOneWidget);
    await tester.tap(find.text('Status (online first)'));
    await tester.pumpAndSettle();

    expect(top('bravo'), lessThan(top('alpha')));
    final settings = {for (final row in await repo.getAllSettings()) row.key: row.value};
    expect(settings['host_sort'], 'status');
  });

  testWidgets('the actions menu copies an SSH command for the host', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await repo.insertServer(server(name: 'nas', host: 'nas.lan').copyWith(port: 2222));
    await pump(tester, network: network());

    await tester.tap(find.byKey(ValueKey('servers.card.${app.servers.single.id}.actions')));
    await tester.pumpAndSettle();
    expect(find.text('Ping from this device'), findsOneWidget);
    expect(find.text('Traceroute from this device'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('servers.action.copySsh')));
    await tester.pumpAndSettle();

    expect(copied, 'ssh -p 2222 root@nas.lan');
    expect(find.text('Copied to clipboard'), findsOneWidget);
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
