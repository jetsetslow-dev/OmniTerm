import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/infra/infra_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/infra_view_model.dart';
import 'package:provider/provider.dart';

import 'infra_view_model_test.dart' show psRow;
import 'monitor_view_model_test.dart' show RecordingTransport;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late InfraViewModel vm;
  // The Builder tab registers a back-press guard on this (defect 65).
  late NavigationController nav;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({required String name, String status = 'online'}) => Server(
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
    status: status,
    authStatus: 'ok',
  );

  Future<void> pump(WidgetTester tester, {RecordingTransport? transport}) async {
    await app.start();
    vm = InfraViewModel(app, transport: transport);
    nav = NavigationController();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<InfraViewModel>.value(value: vm),
          ChangeNotifierProvider<NavigationController>.value(value: nav),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: InfraScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RecordingTransport withStack() => RecordingTransport(
    replies: {
      'ps -a --no-trunc': [
        psRow(id: 'a1', name: 'web_front_1', service: 'front'),
        psRow(id: 'a2', name: 'web_db_1', service: 'db', ports: '—'),
      ].join('\n'),
      'images --no-trunc': 'docker\tsha256:abc\tnginx\tlatest\t50MB\t2 days ago',
      'ot_vols': 'docker\tdata\tlocal\t/var/lib/docker/volumes/data\t1.2GB\t0',
      'network ls': 'docker\tn1\tbridge\tbridge\ndocker\tn2\tweb_default\tbridge',
    },
  );

  testWidgets('with nothing online it says so', (tester) async {
    await repo.insertServer(server(name: 'a', status: 'offline'));
    await pump(tester);

    expect(find.byKey(const ValueKey('infra.noHosts')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('all five tabs are present and reachable', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: withStack());

    for (final tab in InfraTab.values) {
      expect(find.byKey(ValueKey('infra.tab.${tab.name}')), findsOneWidget);
    }
    for (final (tab, probe) in [
      (InfraTab.images, 'infra.images.list'),
      (InfraTab.volumes, 'infra.volumes.list'),
      (InfraTab.networks, 'infra.networks.list'),
      (InfraTab.stacks, 'infra.stacks.list'),
    ]) {
      await tester.tap(find.byKey(ValueKey('infra.tab.${tab.name}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(probe)), findsOneWidget, reason: '${tab.name} did not render');
    }
    vm.dispose();
  });

  testWidgets('the stack card shows its project, runtime and running count', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: withStack());

    expect(find.byKey(const ValueKey('infra.stack.docker.web')), findsOneWidget);
    expect(find.text('web'), findsOneWidget);
    expect(find.text('DOCKER'), findsWidgets);
    expect(find.text('2/2'), findsOneWidget);
    vm.dispose();
  });

  testWidgets('services expand and collapse', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: withStack());

    expect(find.text('front'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('infra.stack.web.services')));
    await tester.pumpAndSettle();
    expect(find.text('front'), findsOneWidget);
    expect(find.text('db'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('infra.stack.web.services')));
    await tester.pumpAndSettle();
    expect(find.text('front'), findsNothing);
    vm.dispose();
  });

  testWidgets('bringing a stack down asks first', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = withStack();
    await pump(tester, transport: transport);

    await tester.tap(find.byKey(const ValueKey('infra.stack.web.down')));
    await tester.pumpAndSettle();
    expect(find.text('Bring down web?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('infra.stack.down.cancel')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('down')), isFalse);

    await tester.tap(find.byKey(const ValueKey('infra.stack.web.down')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('infra.stack.down.removeOrphans')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('infra.stack.down.confirm')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains(r'$OT_COMPOSE') && c.contains('down')), isTrue);
    expect(
      transport.commands.any((c) => c.contains(r'$OT_COMPOSE') && c.contains('--remove-orphans')),
      isTrue,
    );
    vm.dispose();
  });

  testWidgets('a remembered downed stack can be edited or forgotten', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = withStack();
    await pump(tester, transport: transport);
    transport.replies = {'ps -a --no-trunc': ''};
    await vm.load();
    await tester.pumpAndSettle();

    expect(vm.downedStacks.single.project, 'web');
    await tester.tap(find.byKey(const ValueKey('infra.downedStack.web.editBuilder')));
    await tester.pumpAndSettle();

    expect(vm.activeTab, InfraTab.builder);
    expect(vm.requestedComposeStack?.name, 'web');
    expect(vm.requestedComposeStack?.workingDir, '/srv/web');
    expect(find.byKey(const ValueKey('infra.builder')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('a stack with no compose metadata says why it has no actions', (tester) async {
    // Silently omitting the buttons leaves the user wondering what they did wrong.
    await repo.insertServer(server(name: 'nas'));
    await pump(
      tester,
      transport: RecordingTransport(
        replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1', workdir: '', configs: ''),
        },
      ),
    );

    expect(find.text('No compose metadata for stack actions'), findsOneWidget);
    expect(find.byKey(const ValueKey('infra.stack.web.down')), findsNothing);
    vm.dispose();
  });

  testWidgets('an in-use image can be force-removed, but asks first', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: withStack());
    await tester.tap(find.byKey(const ValueKey('infra.tab.images')));
    await tester.pumpAndSettle();

    expect(find.text('IN USE'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove image'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('infra.image.remove.dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('infra.image.remove.cancel')));
    await tester.pumpAndSettle();
    expect(vm.actionOutput, isNull);
    vm.dispose();
  });

  testWidgets('built-in networks cannot be deleted', (tester) async {
    // Removing them breaks container networking and they cannot be recreated identically.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: withStack());
    await tester.tap(find.byKey(const ValueKey('infra.tab.networks')));
    await tester.pumpAndSettle();

    expect(find.text('BUILT-IN'), findsOneWidget);
    expect(find.byKey(const ValueKey('infra.network.n1.remove')), findsNothing);
    expect(find.byKey(const ValueKey('infra.network.n2.remove')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('deleting a volume warns that the data is unrecoverable', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = withStack();
    await pump(tester, transport: transport);
    await tester.tap(find.byKey(const ValueKey('infra.tab.volumes')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('infra.volume.data.remove')));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be recovered'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('infra.volume.remove.cancel')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('volume rm')), isFalse);
    vm.dispose();
  });

  testWidgets('pruning volumes asks first and says what it deletes', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = withStack();
    await pump(tester, transport: transport);
    await tester.tap(find.byKey(const ValueKey('infra.tab.volumes')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('infra.volumes.prune')));
    await tester.pumpAndSettle();
    expect(find.textContaining('including named ones'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('infra.volumes.prune.confirm')));
    await tester.pumpAndSettle();
    expect(transport.commands.any((c) => c.contains('volume prune -a -f')), isTrue);
    vm.dispose();
  });

  group('an unsaved compose draft survives', () {
    /// Types [name] into the builder's project field, which is the cheapest edit that proves the
    /// whole draft came back rather than just the widget being rebuilt.
    /// Makes a change the dirty check can see.
    ///
    /// `isDirty` compares *rendered YAML*, so the project and top-level name fields do not count —
    /// they are deploy parameters, not document content. That is Kotlin's behaviour too
    /// (`ui/ComposeBuilder.kt:1222`). Editing the raw document is the unambiguous dirty edit.
    Future<void> editTheDocument(WidgetTester tester, String yaml) async {
      await tester.tap(find.byKey(const ValueKey('infra.builder.rawToggle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('infra.builder.raw')), yaml);
      await tester.pumpAndSettle();
    }

    Future<void> showTab(WidgetTester tester, String tab) async {
      await tester.tap(find.byKey(ValueKey('infra.tab.$tab')));
      await tester.pumpAndSettle();
    }

    testWidgets('a switch to another Infra tab and back', (tester) async {
      // The defect: the draft lived in the tab's State, and InfraScreen builds BuilderTab only
      // while the Builder tab is selected — so a glance at Stacks destroyed an unsaved stack with
      // no warning and nothing to undo.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());

      await showTab(tester, 'builder');
      await editTheDocument(tester, 'services:\n  web:\n    image: nginx\n');

      await showTab(tester, 'stacks');
      expect(
        find.byKey(const ValueKey('infra.builder')),
        findsNothing,
        reason: 'the tab really is torn down, so this is not a no-op round trip',
      );

      await showTab(tester, 'builder');
      expect(find.textContaining('image: nginx'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('leaving the screen entirely', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());

      await showTab(tester, 'builder');
      await editTheDocument(tester, 'services:\n  web:\n    image: nginx\n');

      // The same view model throughout, because that is what navigating away actually does — the
      // provider lives above the route. Re-running `pump` would build a *new* one and prove
      // nothing about the screen.
      Future<void> showScreen({required bool visible}) async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AppState>.value(value: app),
              ChangeNotifierProvider<InfraViewModel>.value(value: vm),
              ChangeNotifierProvider<NavigationController>.value(value: nav),
            ],
            child: MaterialApp(
              theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
              home: Scaffold(body: visible ? const InfraScreen() : const SizedBox()),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await showScreen(visible: false);
      expect(find.byKey(const ValueKey('infra.builder')), findsNothing);

      await showScreen(visible: true);
      await showTab(tester, 'builder');
      expect(find.textContaining('image: nginx'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('but "New" discards it for good', (tester) async {
      // Otherwise the draft the user explicitly threw away returns on the next visit.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());

      await showTab(tester, 'builder');
      await editTheDocument(tester, 'services:\n  web:\n    image: nginx\n');

      await tester.tap(find.byKey(const ValueKey('infra.builder.new')));
      await tester.pumpAndSettle();
      expect(find.textContaining('image: nginx'), findsNothing);

      await showTab(tester, 'stacks');
      await showTab(tester, 'builder');
      expect(find.textContaining('image: nginx'), findsNothing);
      vm.dispose();
    });
  });

  group('Back on the Builder tab', () {
    Future<void> showTab(WidgetTester tester, String tab) async {
      await tester.tap(find.byKey(ValueKey('infra.tab.$tab')));
      await tester.pumpAndSettle();
    }

    /// Makes a change the dirty check can see.
    ///
    /// `isDirty` compares *rendered YAML*, so the project and top-level name fields do not count —
    /// they are deploy parameters, not document content. That is Kotlin's behaviour too
    /// (`ui/ComposeBuilder.kt:1222`). Editing the raw document is the unambiguous dirty edit.
    Future<void> editTheDocument(WidgetTester tester, String yaml) async {
      await tester.tap(find.byKey(const ValueKey('infra.builder.rawToggle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('infra.builder.raw')), yaml);
      await tester.pumpAndSettle();
    }

    testWidgets('an untouched draft leaves the tab without asking', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());
      await showTab(tester, 'builder');

      expect(nav.navigateBack(), isTrue, reason: 'the tab claims the press');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('infra.builder.discardConfirm')), findsNothing);
      expect(vm.activeTab, InfraTab.stacks);
      vm.dispose();
    });

    testWidgets('an edited draft asks first, and Cancel keeps it', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());
      await showTab(tester, 'builder');
      await editTheDocument(tester, 'services:\n  web:\n    image: nginx\n');

      expect(nav.navigateBack(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('infra.builder.discardConfirm')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('infra.builder.discardConfirm.cancel')));
      await tester.pumpAndSettle();

      expect(vm.activeTab, InfraTab.builder, reason: 'Cancel means stay');
      expect(find.textContaining('image: nginx'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('Discard throws the draft away and leaves the tab', (tester) async {
      // Kotlin's own comment: Back must end in a *visible* navigation. Clearing alone would leave
      // the user on the Builder tab watching it rebuild an empty draft, with no way out.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());
      await showTab(tester, 'builder');
      await editTheDocument(tester, 'services:\n  web:\n    image: nginx\n');

      expect(nav.navigateBack(), isTrue);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('infra.builder.discardConfirm.discard')));
      await tester.pumpAndSettle();

      expect(vm.activeTab, InfraTab.stacks);
      await showTab(tester, 'builder');
      expect(
        find.textContaining('image: nginx'),
        findsNothing,
        reason: 'a discarded draft must not come back through the memento',
      );
      vm.dispose();
    });

    testWidgets('a second Back leaves the screen', (tester) async {
      // The escape hatch: once the tab is gone its handler is unmounted, so the press falls through.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());
      await showTab(tester, 'builder');
      nav.navigateTo(Screen.infra);

      expect(nav.navigateBack(), isTrue);
      await tester.pumpAndSettle();
      expect(vm.activeTab, InfraTab.stacks);

      expect(nav.navigateBack(), isTrue);
      await tester.pumpAndSettle();
      expect(nav.currentScreen, Screen.servers);
      vm.dispose();
    });
  });

  testWidgets('a runtime failure explains itself and keeps the builder reachable', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = withStack()..failure = Exception('permission denied on /var/run/docker.sock');
    await pump(tester, transport: transport);

    expect(find.byKey(const ValueKey('infra.error')), findsOneWidget);
    expect(find.textContaining('permission denied'), findsOneWidget);
    expect(find.textContaining('reach its socket'), findsOneWidget);

    // The builder does not depend on a successful probe.
    await tester.tap(find.byKey(const ValueKey('infra.tab.builder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('infra.builder')), findsOneWidget);
    expect(find.byKey(const ValueKey('infra.builder.deploy')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('a host with no container runtime says that, not "no stacks"', (tester) async {
    // Different facts, and the second explains the first: reporting only "no stacks" sends the user
    // looking for containers on a machine that could not run one. Found on a real Alpine host.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport());

    expect(find.byKey(const ValueKey('infra.stacks.empty')), findsOneWidget);
    expect(find.textContaining('No container runtime on this host'), findsOneWidget);
    expect(find.byKey(const ValueKey('infra.error')), findsNothing);
    vm.dispose();
  });

  testWidgets('a host that does run containers, but has none, says so', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    // The runtimes probe answers, so Docker is present — there is simply nothing to show.
    await pump(tester, transport: RecordingTransport(replies: {'command -v docker': 'docker'}));

    expect(find.byKey(const ValueKey('infra.stacks.empty')), findsOneWidget);
    expect(find.textContaining('No compose stacks on this host'), findsOneWidget);
    expect(find.textContaining('No container runtime'), findsNothing);
    vm.dispose();
  });

  testWidgets('action output is shown verbatim and can be dismissed', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    final transport = withStack()
      ..replies = {
        ...withStack().replies,
        'restart': 'Error response from daemon: no such container',
      };
    await pump(tester, transport: transport);

    await tester.tap(find.byKey(const ValueKey('infra.stack.web.restart')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restart'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no such container'), findsOneWidget);
    expect(find.byKey(const ValueKey('infra.actionOutput.copy')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('infra.actionOutput.dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('infra.actionOutput')), findsNothing);
    vm.dispose();
  });

  testWidgets('hide-sensitive-info masks the host in the picker', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: withStack());
    expect(find.textContaining('nas'), findsWidgets);

    HostDisplay.instance.hideSensitiveInfo = true;
    await tester.pumpAndSettle();
    expect(find.textContaining('10.0.0.1'), findsNothing);
    vm.dispose();
  });

  group('the per-service dialogs', () {
    Future<void> openServiceMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('infra.tab.stacks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('infra.stack.web.services')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('infra.service.web.front.menu')));
      await tester.pumpAndSettle();
    }

    testWidgets('scaling asks for a count and sends it', (tester) async {
      // The command was ported with the screens; nothing could reach it until now.
      await repo.insertServer(server(name: 'nas'));
      final transport = withStack();
      await pump(tester, transport: transport);
      await openServiceMenu(tester);

      await tester.tap(find.text('Scale…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('infra.scale.dialog')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('infra.scale.replicas')), '3');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('infra.scale.confirm')));
      await tester.pumpAndSettle();

      expect(
        transport.commands.any((c) => c.contains('--scale') && c.contains("front'=3")),
        isTrue,
        reason: 'the typed count reaches the host',
      );
      vm.dispose();
    });

    testWidgets('scaling to zero is allowed, but a negative count is not', (tester) async {
      // Draining a service without tearing the stack down is a real thing to want; a negative
      // replica count is a typo.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());
      await openServiceMenu(tester);
      await tester.tap(find.text('Scale…'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('infra.scale.replicas')), '0');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('infra.scale.confirm'))).onPressed,
        isNotNull,
      );

      await tester.enterText(find.byKey(const ValueKey('infra.scale.replicas')), '-2');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('infra.scale.confirm'))).onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('infra.scale.cancel')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    testWidgets('ports are listed from what the host already reported', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      final transport = withStack();
      await pump(tester, transport: transport);
      final before = transport.commands.length;
      await openServiceMenu(tester);

      await tester.tap(find.text('Ports'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('infra.ports.dialog')), findsOneWidget);
      expect(find.text('0.0.0.0:8080->80/tcp'), findsOneWidget);
      expect(
        transport.commands.length,
        before,
        reason: 'docker ps already said this; asking again could disagree with the list on screen',
      );
      await tester.tap(find.byKey(const ValueKey('infra.ports.close')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    testWidgets('a service that publishes nothing says so, rather than showing an empty list', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, transport: withStack());
      await tester.tap(find.byKey(const ValueKey('infra.tab.stacks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('infra.stack.web.services')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('infra.service.web.db.menu')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ports'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('infra.ports.none')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('infra.ports.close')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    testWidgets('logs open in a sheet, not in the one-line result banner', (tester) async {
      // Pages of log text through the result banner made both the banner and the logs unusable.
      await repo.insertServer(server(name: 'nas'));
      final transport = withStack()
        ..replies = {
          ...withStack().replies,
          'logs --tail 200': 'front-1  | listening on 8080\nfront-1  | ready',
        };
      await pump(tester, transport: transport);
      await openServiceMenu(tester);

      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Logs'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('infra.logs.text')), findsOneWidget);
      expect(find.textContaining('listening on 8080'), findsOneWidget);
      expect(find.byKey(const ValueKey('infra.actionOutput')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('infra.logs.close')));
      await tester.pumpAndSettle();
      vm.dispose();
    });

    testWidgets('a service that has logged nothing says that', (tester) async {
      // An empty sheet is indistinguishable from one still loading.
      await repo.insertServer(server(name: 'nas'));
      final transport = withStack()..replies = {...withStack().replies, 'logs --tail 200': '   '};
      await pump(tester, transport: transport);
      await openServiceMenu(tester);

      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Logs'));
      await tester.pumpAndSettle();

      expect(find.textContaining('logged nothing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('infra.logs.close')));
      await tester.pumpAndSettle();
      vm.dispose();
    });
  });

  testWidgets('a settled probe with nothing found shows the empty state, not a spinner', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester, transport: RecordingTransport(replies: const {}));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('infra.firstLoad')), findsNothing);
    vm.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });
}
