import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/term/tmux_bootstrap.dart';
import 'package:omniterm/l10n/app_localizations.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/servers/attach_tmux_dialog.dart';
import 'package:omniterm/ui/theme/colors.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:omniterm/ui/widgets/omni_components.dart';

import 'support/fake_secure_storage.dart';
import 'support/fake_shell_transport.dart';

/// Hosts ⋮ › Attach existing tmux…, as Kotlin's `AttachTmuxDialog`.
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late FakeShellTransport ssh;
  late ShellViewModel shell;
  late NavigationController navigation;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    ssh = FakeShellTransport();
    navigation = NavigationController();
  });

  tearDown(() async {
    shell.dispose();
    app.dispose();
    await ssh.dispose();
    await db.close();
  });

  Server host() => const Server(
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

  /// Opens the dialog on a host whose listing answers [listing].
  Future<void> open(WidgetTester tester, String listing) async {
    await tester.runAsync(() async {
      await repo.insertServer(host());
      await app.start();
      await Future<void>.delayed(Duration.zero);
    });
    shell = ShellViewModel(app, transport: ssh);
    ssh.execAnswers[tmuxListSessionsCommand] = listing;
    ssh.execAnswers[tmuxSessionProbeCommand('main')] = tmuxSessionPresentMarker;
    navigation.navigateTo(Screen.monitor);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAttachTmuxDialog(context, shell, app.servers.single, navigation: navigation),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the sessions, and says which cannot be attached', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await open(tester, '${now - 7200} 0 3 main\n${now - 90000} 1 1 my project\n');

    expect(find.text('tmux sessions on nas'), findsOneWidget);
    expect(
      find.text(
        'Attaching joins the session itself, as tmux attach does: every client shows the same '
        'window. Terminate in OmniTerm ends it on the server; Leave keeps it running.',
      ),
      findsOneWidget,
    );
    expect(find.text('3 windows · detached · Started 2h 00m ago'), findsOneWidget);
    expect(find.text('1 window · attached elsewhere · Started 1d 01h ago'), findsOneWidget);
    expect(
      find.text(
        'Rename it on the host to attach: letters, digits, - and _ only, not starting with -.',
      ),
      findsOneWidget,
    );
    final main = tester.widget<OmniCard>(find.byKey(const ValueKey('tmux.attach.session.main')));
    final spaced = tester.widget<OmniCard>(
      find.byKey(const ValueKey('tmux.attach.session.my project')),
    );
    expect(main.leftAccent, OmniColors.cyan);
    expect(main.onTap, isNotNull);
    expect(spaced.leftAccent, isNull);
    expect(spaced.onTap, isNull);
  });

  testWidgets('tapping a session attaches it and opens the terminal', (tester) async {
    await open(tester, '1700000100 0 1 main\n');

    await tester.tap(find.byKey(const ValueKey('tmux.attach.session.main')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tmux.attach.dialog')), findsNothing);
    expect(navigation.currentScreen, Screen.shell);
    expect(shell.current?.tmuxName, 'main');
  });

  testWidgets('an empty host and a host without tmux each say so', (tester) async {
    await open(tester, '');
    expect(find.byKey(const ValueKey('tmux.attach.none')), findsOneWidget);
    expect(find.text('No tmux sessions are running on nas.'), findsOneWidget);

    ssh.execAnswers[tmuxListSessionsCommand] = '$tmuxMissingMarker\n';
    await tester.tap(find.byKey(const ValueKey('tmux.attach.refresh')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('tmux is not installed on nas.'), findsOneWidget);
  });

  testWidgets('a failed listing shows why, and Close stops it', (tester) async {
    await open(tester, 'SSH Error: connection refused\n');

    final error = tester.widget<Text>(find.byKey(const ValueKey('tmux.attach.error')));
    expect(error.data, 'SSH Error: connection refused');
    expect(error.style?.color, OmniColors.red);

    await tester.tap(find.byKey(const ValueKey('tmux.attach.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmux.attach.dialog')), findsNothing);
    expect(shell.tmuxAttachServer, isNull);
  });
}
