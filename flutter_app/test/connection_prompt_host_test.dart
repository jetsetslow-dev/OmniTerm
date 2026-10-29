import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_commands.dart' show tmuxCheckCommand, tmuxInstallCommand;
import 'package:omniterm/data/ssh/dartssh_transport.dart' show SshHostKeyException;
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/l10n/app_localizations.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:omniterm/ui/widgets/connection_prompt_host.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';
import 'support/fake_shell_transport.dart';

/// The prompts [ShellViewModel.connect] can raise before opening a terminal, ported from
/// `TmuxInstallDialog` and `OfflineConnectDialog` (`ui/AppUi.kt:617`, `:671`).
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late ShellViewModel vm;
  late FakeShellTransport ssh;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    ssh = FakeShellTransport();
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await ssh.dispose();
    await db.close();
  });

  Server host({bool persistent = true, String status = 'online'}) => Server(
    id: 0,
    name: 'nas',
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
    persistentSession: persistent,
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

  /// A bounded pump.
  ///
  /// `pumpAndSettle` cannot be used once a connection succeeds: a live [ShellSession] runs a ~16 ms
  /// publish timer, so the frame loop never goes quiet and the call hangs until its timeout.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    bool probed = false,
    String status = 'online',
    bool persistent = true,
    SshHostKeyTrust? trust,
  }) async {
    // `runAsync` because these touch a real drift database. `testWidgets` installs a fake clock, and
    // a future that resolves off a real timer never completes under it — the test simply hangs.
    await tester.runAsync(() async {
      await repo.insertServer(host(persistent: persistent, status: status));
      await app.start();
      await Future<void>.delayed(Duration.zero);
    });
    vm = ShellViewModel(app, transport: ssh, hasProbed: (_) => probed, hostKeyTrust: trust);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ShellViewModel>.value(value: vm),
          // The tmux install asks first, as every sudo action does. No App Lock and no screen
          // lock here, so it asks plainly.
          ChangeNotifierProvider<AppLockController>.value(value: AppLockController(repo)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const ConnectionPromptHost(child: Scaffold(body: Text('the app'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('nothing is shown until a host actually lacks tmux', (tester) async {
    ssh.execAnswers[tmuxCheckCommand] = 'yes';
    await pump(tester);

    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsNothing);
  });

  testWidgets('a host without tmux is asked about, not silently refused', (tester) async {
    ssh.execAnswers[tmuxCheckCommand] = 'no';
    await pump(tester);

    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsOneWidget);
    expect(find.text('Install tmux on nas?'), findsOneWidget);
    // All three of Kotlin's choices are offered.
    expect(find.byKey(const ValueKey('tmux.install.confirm')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmux.install.plain')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmux.install.cancel')), findsOneWidget);
  });

  testWidgets('connect non-resumable closes the prompt and opens a plain shell', (tester) async {
    ssh.execAnswers[tmuxCheckCommand] = 'no';
    await pump(tester);
    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('tmux.install.plain')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);

    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsNothing);
    expect(ssh.opened, hasLength(1));
  });

  testWidgets('cancelling closes the prompt and connects nothing', (tester) async {
    ssh.execAnswers[tmuxCheckCommand] = 'no';
    await pump(tester);
    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('tmux.install.cancel')));
    await settle(tester);

    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsNothing);
    expect(ssh.opened, isEmpty);
    expect(
      vm.tmuxPromptServer,
      isNull,
      reason: 'stale pending state would swallow the next connection attempt',
    );
  });

  testWidgets('the install asks first, and a cancelled check installs nothing', (tester) async {
    ssh.execAnswers[tmuxCheckCommand] = 'no';
    await pump(tester);
    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('tmux.install.confirm')));
    await settle(tester);
    expect(find.byKey(const ValueKey('sudoAuth.plain')), findsOneWidget);
    expect(find.text('Run this with sudo on nas?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sudoAuth.cancel')));
    await settle(tester);
    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsOneWidget);
    expect(vm.tmuxInstalling, isFalse);
    expect(
      ssh.commands.where((c) => c.contains('apt-get')),
      isEmpty,
      reason: 'nothing may run as root before the user says so',
    );
  });

  testWidgets('a failed install keeps the prompt up and shows the output', (tester) async {
    ssh
      ..execAnswers[tmuxCheckCommand] = 'no'
      ..streamChunks = const ['E: Unable to locate package tmux\n'];
    await pump(tester);
    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('tmux.install.confirm')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('sudo.confirm.continue')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);

    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsOneWidget);
    final output = tester
        .widget<SelectableText>(find.byKey(const ValueKey('tmux.install.output')))
        .data!;
    expect(output, contains('Unable to locate package'));
    expect(output, contains('Install did not complete'));
    // No saved sudo password: sudo must refuse at once rather than wait on stdin for one.
    expect(ssh.commands, contains(tmuxInstallCommand(withSudoPassword: false)));
    expect(ssh.opened, isEmpty);
  });

  testWidgets('a successful install closes the prompt and connects', (tester) async {
    ssh
      ..execAnswers[tmuxCheckCommand] = 'no'
      ..streamChunks = const ['tmux installed\n'];
    await pump(tester);
    await tester.runAsync(() => vm.connect(vm.connectableServers.single));
    await settle(tester);

    // The re-probe after installing now answers yes.
    ssh.execAnswers[tmuxCheckCommand] = 'yes';
    await tester.tap(find.byKey(const ValueKey('tmux.install.confirm')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('sudo.confirm.continue')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);

    expect(find.byKey(const ValueKey('tmux.install.dialog')), findsNothing);
    expect(ssh.opened, hasLength(1));
  });

  /// The "appears offline" confirmation, now raised by the view model so **every** route to a
  /// terminal is covered — the host list, the Infra tab's container shell, the quick-connect sheet,
  /// a shortcut and a quick action. Kotlin gates it in `connectTerminal` for the same reason.
  group('offline confirmation', () {
    testWidgets('a probed, offline host is asked about before connecting', (tester) async {
      await pump(tester, probed: true, status: 'offline');

      await tester.runAsync(() => vm.connect(app.servers.single));
      await settle(tester);

      expect(find.byKey(const ValueKey('offline.connect.dialog')), findsOneWidget);
      expect(ssh.opened, isEmpty);
    });

    testWidgets('a host nothing has probed connects without being asked', (tester) async {
      // A freshly added host is stored as `offline`; warning about it would be a false alarm.
      await pump(tester, probed: false, status: 'offline');

      await tester.runAsync(() => vm.connect(app.servers.single));
      await settle(tester);

      expect(find.byKey(const ValueKey('offline.connect.dialog')), findsNothing);
      expect(ssh.opened, hasLength(1));
    });

    testWidgets('connect anyway proceeds', (tester) async {
      await pump(tester, probed: true, status: 'offline');
      await tester.runAsync(() => vm.connect(app.servers.single));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('offline.connect.confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);

      expect(find.byKey(const ValueKey('offline.connect.dialog')), findsNothing);
      expect(ssh.opened, hasLength(1));
    });

    testWidgets('cancel connects nothing and clears the prompt', (tester) async {
      await pump(tester, probed: true, status: 'offline');
      await tester.runAsync(() => vm.connect(app.servers.single));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('offline.connect.cancel')));
      await settle(tester);

      expect(find.byKey(const ValueKey('offline.connect.dialog')), findsNothing);
      expect(ssh.opened, isEmpty);
      expect(vm.offlineConnectPromptServer, isNull);
    });

    testWidgets('the offline question is asked before the tmux round trip', (tester) async {
      // No point asking a host whether it has tmux when the last check said it was not answering.
      ssh.execAnswers[tmuxCheckCommand] = 'no';
      await pump(tester, probed: true, status: 'offline', persistent: true);

      await tester.runAsync(() => vm.connect(app.servers.single));
      await settle(tester);

      expect(find.byKey(const ValueKey('offline.connect.dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmux.install.dialog')), findsNothing);
      expect(
        ssh.commands,
        isEmpty,
        reason: 'the probe costs a round trip to a host we already believe is down',
      );
    });
  });

  /// Kotlin's "Host Key Changed" dialog. Flutter used to put a paragraph in the error area telling
  /// the user to remove the pinned key under Tools and connect again.
  group('a changed host key', () {
    Future<SshHostKeyTrust> pinnedTrust(WidgetTester tester) async {
      final store = InMemoryHostKeyStore();
      await tester.runAsync(() => store.write('10.0.0.1|ssh-ed25519', 'SHA256:old'));
      return SshHostKeyTrust(store);
    }

    testWidgets('asks the user, in Kotlin\'s words', (tester) async {
      final trust = await pinnedTrust(tester);
      await pump(tester, persistent: false, trust: trust);
      ssh.failure = SshHostKeyException('changed', HostKeyVerdict.changed);

      await tester.runAsync(() => vm.connect(vm.connectableServers.single));
      await settle(tester);

      expect(find.byKey(const ValueKey('hostKeyChanged.dialog')), findsOneWidget);
      expect(find.text('Host Key Changed'), findsOneWidget);
      expect(find.textContaining('has changed since you last connected'), findsOneWidget);
      expect(find.text('Remove & Reconnect'), findsOneWidget);
      // As Kotlin: the terminal says why behind the dialog, and still does after Cancel.
      expect(vm.error, 'Host key verification failed.');
    });

    testWidgets('Remove & Reconnect forgets the pinned key and connects again', (tester) async {
      final trust = await pinnedTrust(tester);
      await pump(tester, persistent: false, trust: trust);
      ssh.failure = SshHostKeyException('changed', HostKeyVerdict.changed);
      await tester.runAsync(() => vm.connect(vm.connectableServers.single));
      await settle(tester);

      ssh.failure = null;
      await tester.tap(find.byKey(const ValueKey('hostKeyChanged.remove')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);

      expect(await tester.runAsync(() => trust.hasPinnedKey('10.0.0.1', 22)), isFalse);
      expect(ssh.openedWith, hasLength(2), reason: 'one refused attempt, then the reconnect');
      expect(find.byKey(const ValueKey('hostKeyChanged.dialog')), findsNothing);
    });

    testWidgets('Cancel keeps the pinned key and leaves nothing behind', (tester) async {
      final trust = await pinnedTrust(tester);
      await pump(tester, persistent: false, trust: trust);
      ssh.failure = SshHostKeyException('changed', HostKeyVerdict.changed);
      await tester.runAsync(() => vm.connect(vm.connectableServers.single));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('hostKeyChanged.cancel')));
      await settle(tester);

      expect(await tester.runAsync(() => trust.hasPinnedKey('10.0.0.1', 22)), isTrue);
      expect(find.byKey(const ValueKey('hostKeyChanged.dialog')), findsNothing);
      expect(vm.hostKeyChangedServer, isNull);
      expect(ssh.openedWith, hasLength(1));
    });
  });
}
