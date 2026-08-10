import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/shell/shell_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';
import 'support/fake_shell_transport.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late FakeShellTransport transport;
  late ShellViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    transport = FakeShellTransport();
    HostDisplay.instance.hideSensitiveInfo = false;
  });

  tearDown(() async {
    app.dispose();
    await transport.dispose();
    await db.close();
  });

  Server server({required String name, String status = 'online', bool persistent = false}) =>
      Server(
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

  Future<void> pump(WidgetTester tester, {bool withTransport = true}) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = ShellViewModel(app, transport: withTransport ? transport : null);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ShellViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: ShellScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
  }

  Future<void> connect(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('shell.connect')));
    await tester.pumpAndSettle();
  }

  group('with nothing to connect to', () {
    testWidgets('no hosts at all asks for one', (tester) async {
      await pump(tester);

      expect(find.byKey(const ValueKey('shell.empty')), findsOneWidget);
      expect(find.text('Add a host first.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('hosts that are all offline point at the Hosts tab', (tester) async {
      // A different problem with a different fix, so it gets a different sentence — and the Hosts
      // tab is the only place that warns before forcing SSH to a host believed to be down.
      await repo.insertServer(server(name: 'nas', status: 'offline'));
      await pump(tester);

      expect(find.textContaining('No online hosts'), findsOneWidget);
      expect(find.textContaining('Hosts tab'), findsOneWidget);
      await finish(tester);
    });
  });

  group('the connect prompt', () {
    testWidgets('names the host it is about to connect to', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);

      expect(find.text('nas'), findsOneWidget);
      expect(find.text('root@10.0.0.1:22'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('hides the address when hide-addresses is on', (tester) async {
      // The terminal is the screen most likely to be on a shared display.
      await repo.insertServer(server(name: 'nas'));
      HostDisplay.instance.hideSensitiveInfo = true;
      await pump(tester);

      expect(find.text('root@10.0.0.1:22'), findsNothing);
      HostDisplay.instance.hideSensitiveInfo = false;
      await finish(tester);
    });

    testWidgets('without a transport the button is disabled and says why', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, withTransport: false);

      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('shell.connect')));
      expect(button.onPressed, isNull);
      expect(find.byKey(const ValueKey('shell.unavailable')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a failed connect is reported on the prompt, not swallowed', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      transport.failure = StateError('host key changed');
      await pump(tester);

      await connect(tester);

      expect(find.byKey(const ValueKey('shell.error')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shell.connect')),
        findsOneWidget,
        reason: 'the user can try again',
      );
      await finish(tester);
    });

    testWidgets('the connecting view names the phase', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      transport = FakeShellTransport(phases: const ['Authenticating…'])..gate = Completer<void>();
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('shell.connect')));
      await tester.pump();

      // A generic spinner tells the user nothing about which step is hanging.
      expect(find.text('Authenticating…'), findsOneWidget);

      transport.gate!.complete();
      await tester.pumpAndSettle();
      await finish(tester);
    });
  });

  group('a live terminal', () {
    testWidgets('shows the grid, the key bar and the session chip', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      expect(find.byKey(const ValueKey('shell.surface')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.keyBar')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.sessionBar')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('reports the real measured grid, not 80x24', (tester) async {
      // The remote is told the window size; getting it wrong misdraws every full-screen app.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      final resizes = transport.opened.single.resizes;
      expect(resizes, isNotEmpty);
      expect(resizes.last.$1, greaterThan(24), reason: 'a 1000px-wide surface is wide');
      await finish(tester);
    });

    testWidgets('a key cap sends its sequence', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await tester.tap(find.byKey(const ValueKey('shell.key.↑')));
      await tester.pumpAndSettle();

      expect(transport.opened.single.writes.single, '[A'.codeUnits);
      await finish(tester);
    });

    testWidgets('a modifier shows as armed and disarms after one key', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await tester.tap(find.byKey(const ValueKey('shell.key.CTRL')));
      await tester.pumpAndSettle();
      expect(vm.ctrl, isTrue);

      await tester.tap(find.byKey(const ValueKey('shell.key.-')));
      await tester.pumpAndSettle();

      expect(vm.ctrl, isFalse, reason: 'a forgotten latch fires on the next unrelated key');
      await finish(tester);
    });

    testWidgets('the layers swap without moving SYM and FN', (tester) async {
      // A cap that moves between layers gets pressed by mistake, and on a terminal a mis-pressed
      // key is a command nobody meant to run.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      Offset symCentre() => tester.getCenter(find.byKey(const ValueKey('shell.key.SYM')));
      final navPosition = symCentre();

      await tester.tap(find.byKey(const ValueKey('shell.key.FN')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.key.F7')), findsOneWidget);
      expect(symCentre(), navPosition);

      await tester.tap(find.byKey(const ValueKey('shell.key.SYM')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey(r'shell.key.$')), findsOneWidget);
      expect(symCentre(), navPosition);
      await finish(tester);
    });

    testWidgets('read-only says so and offers only the keys that work', (tester) async {
      // The defect: read-only kept the full key bar, so two dozen controls looked live while
      // `sendKey` silently dropped all but page up and page down. On a terminal that is worse than
      // it sounds — the user cannot tell an ignored key from an unresponsive remote.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      expect(find.byKey(const ValueKey('shell.key.↵')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.keyBar.readOnly')), findsOneWidget);
      expect(find.textContaining('READ ONLY'), findsWidgets);
      for (final gone in ['↵', 'ESC', 'TAB', '↑']) {
        expect(
          find.byKey(ValueKey('shell.key.$gone')),
          findsNothing,
          reason: '$gone does nothing in read-only and must not look live',
        );
      }
      expect(find.byKey(const ValueKey('shell.key.PGUP')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.key.PGDN')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('read-only still writes nothing to the remote', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.key.PGUP')));
      await tester.pumpAndSettle();

      // Page up scrolls the local buffer; it is not a keystroke the remote ever sees.
      expect(transport.opened.single.writes, isEmpty);
      await finish(tester);
    });

    testWidgets('leaving read-only brings the full bar back', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.keyBar.readOnly')), findsNothing);
      expect(find.byKey(const ValueKey('shell.key.↵')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('scrolling back offers a way to the bottom', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      for (var i = 0; i < 200; i++) {
        transport.opened.single.emit('line $i\r\n');
      }
      await tester.pump(const Duration(milliseconds: 30));

      expect(find.byKey(const ValueKey('shell.jumpToBottom')), findsNothing);

      await tester.drag(find.byKey(const ValueKey('shell.surface')), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.jumpToBottom')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shell.jumpToBottom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.jumpToBottom')), findsNothing);
      await finish(tester);
    });
  });

  group('when a session ends', () {
    testWidgets('a remote exit names the exit status', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await transport.opened.single.endByRemoteExit(status: 130);
      await tester.pumpAndSettle();

      expect(find.textContaining('exit 130'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a dropped connection is not called an exit', (tester) async {
      // The remote may well still be running; saying the shell ended is a lie the user acts on.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      transport.opened.single.emit('the last thing it said\r\n');
      await tester.pump(const Duration(milliseconds: 30));

      await transport.opened.single.dropConnection();
      await tester.pumpAndSettle();

      expect(find.textContaining('Connection lost'), findsOneWidget);
      expect(find.textContaining('exit'), findsNothing);
      await finish(tester);
    });

    testWidgets('the dead session stays until dismissed', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      await transport.opened.single.dropConnection();
      await tester.pumpAndSettle();

      expect(vm.sessions, hasLength(1), reason: 'the scrollback is the evidence of why');

      await tester.tap(find.byKey(const ValueKey('shell.dismiss')));
      await tester.pumpAndSettle();

      expect(vm.sessions, isEmpty);
      expect(find.byKey(const ValueKey('shell.connect')), findsOneWidget);
      await finish(tester);
    });
  });

  group('the transcript', () {
    testWidgets('a long press opens the scrollback as selectable text', (tester) async {
      // The surface paints a grid, so there is nothing on it to select — which left the one thing
      // people do with terminal output, copy it, impossible.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      transport.opened.single.emit('uptime\r\n');
      transport.opened.single.emit('load average: 0.14\r\n');
      await tester.pump(const Duration(milliseconds: 30));

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();

      final text = tester
          .widget<SelectableText>(find.byKey(const ValueKey('transcript.text')))
          .data!;
      expect(text, contains('uptime'));
      expect(text, contains('load average: 0.14'));
      expect(
        text.split('\n').length,
        2,
        reason: 'the empty grid below the cursor is not output and must not be copied',
      );

      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('output that scrolled out of view is still in the transcript', (tester) async {
      // The reason to reach for this is usually an error that has already scrolled past.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      for (var i = 0; i < 200; i++) {
        transport.opened.single.emit('line $i\r\n');
      }
      await tester.pump(const Duration(milliseconds: 30));

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();

      final text = tester
          .widget<SelectableText>(find.byKey(const ValueKey('transcript.text')))
          .data!;
      expect(text, contains('line 0'), reason: 'the scrollback, not the viewport');
      expect(text, contains('line 199'));

      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('an empty terminal says so rather than offering a copy of nothing', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();

      expect(find.text('Nothing has been printed yet.'), findsOneWidget);
      final copy = tester.widget<IconButton>(find.byKey(const ValueKey('transcript.copyAll')));
      expect(copy.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });
  });

  group('split view', () {
    Future<void> connectTwo(WidgetTester tester) async {
      await repo.insertServer(server(name: 'nas'));
      await repo.insertServer(server(name: 'pi'));
      await pump(tester);
      await connect(tester);
      await tester.tap(find.byKey(const ValueKey('shell.newSession')));
      await tester.pumpAndSettle();
    }

    testWidgets('splitting needs a second session to show', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      expect(
        find.byKey(const ValueKey('shell.split')),
        findsNothing,
        reason: 'one terminal cannot be split against anything',
      );
      await finish(tester);
    });

    testWidgets('two sessions can be shown at once', (tester) async {
      await connectTwo(tester);
      expect(vm.sessions, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shell.split.pick.${vm.sessions.first.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.splitView')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.surface')), findsNWidgets(2));
      await finish(tester);
    });

    testWidgets('the pane that was tapped becomes the one that receives input', (tester) async {
      // Focus is not decoration: keystrokes, the key bar and disconnect all target the focused
      // pane, so a split with ambiguous focus would leave the user guessing where their typing is
      // about to land.
      await connectTwo(tester);
      // Whichever session is *not* current is the one offered for the second pane.
      final other = vm.splitCandidates.single;
      final wasCurrent = vm.current!.id;

      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shell.split.pick.${other.id}')));
      await tester.pumpAndSettle();
      expect(vm.current!.id, wasCurrent, reason: 'splitting must not move focus on its own');

      await tester.tap(find.byKey(ValueKey('shell.pane.${other.id}')));
      await tester.pumpAndSettle();

      expect(vm.current!.id, other.id);
      expect(
        vm.splitSession!.id,
        wasCurrent,
        reason: 'the panes swap rather than one of them vanishing',
      );
      await finish(tester);
    });

    testWidgets('the layout can be rotated and dismissed', (tester) async {
      await connectTwo(tester);
      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shell.split.pick.${vm.sessions.first.id}')));
      await tester.pumpAndSettle();

      expect(find.text('STACK'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell.split.axis')));
      await tester.pumpAndSettle();
      expect(find.text('COLS'), findsOneWidget, reason: 'the button names the layout, not the act');

      await tester.tap(find.byKey(const ValueKey('shell.split.single')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.splitView')), findsNothing);
      expect(find.byKey(const ValueKey('shell.surface')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('closing a split session falls back to a single view', (tester) async {
      // Otherwise the screen holds an id for a terminal that no longer exists.
      await connectTwo(tester);
      final first = vm.sessions.first;

      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shell.split.pick.${first.id}')));
      await tester.pumpAndSettle();
      expect(vm.isSplit, isTrue);

      vm.close(first);
      await tester.pumpAndSettle();

      expect(vm.isSplit, isFalse);
      expect(find.byKey(const ValueKey('shell.splitView')), findsNothing);
      await finish(tester);
    });
  });

  group('sessions left running', () {
    testWidgets('a closed persistent session is offered again, and forgetting explains itself', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas', persistent: true));
      await pump(tester);
      await connect(tester);
      expect(
        find.byKey(const ValueKey('shell.resumable')),
        findsNothing,
        reason: 'it is open in a tab',
      );

      final row = (await repo.getPersistentSessions()).single;
      vm.close(vm.sessions.single);
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('shell.resumable.${row.tmuxName}')), findsOneWidget);
      expect(find.textContaining('still running on their servers'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('shell.resumable.${row.tmuxName}.forget')));
      await tester.pumpAndSettle();
      // The distinction that matters: this is a pointer on this device, not the session itself.
      expect(find.textContaining('keeps running on the server'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shell.resumable.forget.cancel')));
      await tester.pumpAndSettle();
      expect(await repo.getPersistentSessions(), hasLength(1));

      await tester.tap(find.byKey(ValueKey('shell.resumable.${row.tmuxName}.forget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.resumable.forget.confirm')));
      await tester.pumpAndSettle();
      expect(await repo.getPersistentSessions(), isEmpty);
      await finish(tester);
    });

    testWidgets('a non-persistent host leaves nothing behind', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      vm.close(vm.sessions.single);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.resumable')), findsNothing);
      expect(await repo.getPersistentSessions(), isEmpty);
      await finish(tester);
    });
  });

  group('quick connect', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('shell.quickConnect')));
      await tester.pumpAndSettle();
    }

    testWidgets('connects to a host that is never added to the list', (tester) async {
      // The whole feature: a one-off connection to a machine you do not want in your fleet, and do
      // not want to clean up afterwards.
      await repo.insertServer(server(name: 'saved'));
      await pump(tester);
      await openSheet(tester);

      expect(find.byKey(const ValueKey('shell.quick.note')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shell.quick.host')), '10.9.9.9');
      await tester.enterText(find.byKey(const ValueKey('shell.quick.port')), '2222');
      await tester.enterText(find.byKey(const ValueKey('shell.quick.username')), 'root');
      await tester.enterText(find.byKey(const ValueKey('shell.quick.password')), 'once');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.quick.connect')));
      await tester.pumpAndSettle();

      // It dialled what was typed...
      expect(transport.openedWith.single.host, '10.9.9.9');
      expect(transport.openedWith.single.port, 2222);
      expect(transport.openedWith.single.username, 'root');
      expect(transport.openedWith.single.password, 'once');

      // ...and left no trace of it.
      final saved = await repo.getAllServers();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'saved');
      await finish(tester);
    });

    testWidgets('connect stays disabled until there is something to connect to', (tester) async {
      await repo.insertServer(server(name: 'saved'));
      await pump(tester);
      await openSheet(tester);

      FilledButton button() =>
          tester.widget<FilledButton>(find.byKey(const ValueKey('shell.quick.connect')));
      expect(button().onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('shell.quick.host')), '10.9.9.9');
      await tester.pumpAndSettle();
      expect(button().onPressed, isNull, reason: 'a host with no user is not a connection');

      await tester.enterText(find.byKey(const ValueKey('shell.quick.username')), 'root');
      await tester.pumpAndSettle();
      expect(button().onPressed, isNotNull);

      await tester.enterText(find.byKey(const ValueKey('shell.quick.port')), 'abc');
      await tester.pumpAndSettle();
      expect(button().onPressed, isNull, reason: 'a port that is not a number is not a port');
      await finish(tester);
    });

    testWidgets('an empty password is allowed, for a key-less or agent host', (tester) async {
      await repo.insertServer(server(name: 'saved'));
      await pump(tester);
      await openSheet(tester);

      await tester.enterText(find.byKey(const ValueKey('shell.quick.host')), '10.9.9.9');
      await tester.enterText(find.byKey(const ValueKey('shell.quick.username')), 'root');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.quick.connect')));
      await tester.pumpAndSettle();

      expect(transport.openedWith, hasLength(1));
      expect(await repo.getAllServers(), hasLength(1));
      await finish(tester);
    });

    testWidgets('closing the sheet connects to nothing', (tester) async {
      await repo.insertServer(server(name: 'saved'));
      await pump(tester);
      await openSheet(tester);

      await tester.enterText(find.byKey(const ValueKey('shell.quick.host')), '10.9.9.9');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.quick.close')));
      await tester.pumpAndSettle();

      expect(transport.openedWith, isEmpty);
      await finish(tester);
    });

    testWidgets('without a transport there is nothing to offer', (tester) async {
      await repo.insertServer(server(name: 'saved'));
      await pump(tester, withTransport: false);

      final button = tester.widget<TextButton>(find.byKey(const ValueKey('shell.quickConnect')));
      expect(button.onPressed, isNull);
      await finish(tester);
    });
  });
}
