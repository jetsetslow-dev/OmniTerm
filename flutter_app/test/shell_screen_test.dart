import 'dart:async';
import 'dart:ui' show SemanticsActionEvent, Tristate;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/shell/shell_screen.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/widgets/app_lock_gate.dart';
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

  Future<void> pump(
    WidgetTester tester, {
    bool withTransport = true,
    Size size = const Size(1000, 1400),
    double textScale = 1,
    AppLockController? lock,
  }) async {
    tester.view.physicalSize = size;
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
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
            // The real gate, not a stand-in: it is the thing that puts an `ExcludeFocus` over the
            // whole app while locked, which is exactly what the terminal's focus has to survive.
            child: lock == null
                ? const Scaffold(body: ShellScreen())
                : AppLockGate(
                    controller: lock,
                    child: const Scaffold(body: ShellScreen()),
                  ),
          ),
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
    testWidgets('scrolls instead of overflowing on a short 200% landscape phone', (tester) async {
      // Negative control on the physical API-32 phone: the old centred Column overflowed by 35px.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, size: const Size(720, 150), textScale: 2);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('shell.connect')), findsOneWidget);
      await finish(tester);
    });

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

    // The hidden 1x1 field owns the platform IME, so "does it have focus" is the same question as
    // "is the software keyboard up". Kotlin ties both to read-only at `ShellScreen.kt:1889` and
    // `:2077`.
    bool keyboardIsUp(WidgetTester tester) =>
        tester.widget<TextField>(find.byKey(const ValueKey('shell.input'))).focusNode!.hasFocus;

    group('a hardware keyboard', () {
      // `TERMINAL_COMPATIBILITY.md` calls hardware keyboards supported, listing "explicit Ctrl-byte
      // mappings, xterm modifiers, and Alt-prefixed input". The handler consulted none of them: it
      // mapped the special keys, sent `event.character` for everything else, and never asked
      // whether Ctrl or Alt was down. Kotlin assigns the event's modifiers before each key
      // (`ui/ShellScreen.kt:2322`).
      Future<void> withModifier(
        WidgetTester tester,
        LogicalKeyboardKey modifier,
        LogicalKeyboardKey key,
      ) async {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      String written() => transport.opened.single.writes.map((b) => String.fromCharCodes(b)).join();

      testWidgets('Ctrl+C sends the interrupt byte', (tester) async {
        // The one every terminal user reaches for first, and it did nothing at all: a Ctrl chord
        // gives `event.character == null`, so the old handler fell through and returned ignored.
        await repo.insertServer(server(name: 'nas'));
        await pump(tester);
        await connect(tester);

        await withModifier(tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyC);

        expect(transport.opened.single.writes.last, [0x03]);
        await finish(tester);
      });

      testWidgets('Ctrl+arrow carries the xterm modifier', (tester) async {
        await repo.insertServer(server(name: 'nas'));
        await pump(tester);
        await connect(tester);

        await withModifier(tester, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.arrowLeft);

        // CSI 1;5D — the modifier parameter is 1 + ctrl(4).
        expect(written(), endsWith('[1;5D'));
        await finish(tester);
      });

      testWidgets('Alt+b is sent as an ESC prefix', (tester) async {
        await repo.insertServer(server(name: 'nas'));
        await pump(tester);
        await connect(tester);

        await withModifier(tester, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.keyB);

        expect(transport.opened.single.writes.last, [0x1b, 0x62]);
        await finish(tester);
      });

      testWidgets('an unmodified key is still plain text', (tester) async {
        await repo.insertServer(server(name: 'nas'));
        await pump(tester);
        await connect(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.pumpAndSettle();

        expect(transport.opened.single.writes.last, 'c'.codeUnits);
        await finish(tester);
      });
    });

    testWidgets('a connected session takes the keyboard without waiting for a tap', (tester) async {
      // Kotlin focuses the hidden input as soon as a pane becomes the focused, writable one
      // (`ShellScreen.kt:1889`), so the user can type into a fresh session immediately. This port
      // required a tap on the grid first — a step Kotlin never asked for, on the screen whose
      // entire purpose is typing.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      expect(keyboardIsUp(tester), isTrue);
      await finish(tester);
    });

    testWidgets('a dismissed keyboard is not re-raised by an unrelated rebuild', (tester) async {
      // The reason the effect compares its three values instead of acting on every build: pressing
      // Back to dismiss the keyboard must stick. Anything that rebuilds the terminal afterwards —
      // here, output arriving — would otherwise summon it again and again.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      expect(keyboardIsUp(tester), isTrue);

      tester.widget<TextField>(find.byKey(const ValueKey('shell.input'))).focusNode!.unfocus();
      await tester.pumpAndSettle();
      expect(keyboardIsUp(tester), isFalse);

      transport.opened.single.emit('later output\r\n');
      await tester.pumpAndSettle();

      expect(keyboardIsUp(tester), isFalse, reason: 'the user dismissed it; it stays dismissed');
      await finish(tester);
    });

    testWidgets('closing the copy sheet hands the keyboard back to the terminal', (tester) async {
      // Kotlin's copy dialog restores focus and the keyboard on dismiss, unless the session is
      // read-only (`ShellScreen.kt:2555`). Flutter's counterpart is the transcript sheet, opened by
      // a long press on the grid — a different shape, so the contract is checked rather than
      // assumed.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      expect(keyboardIsUp(tester), isTrue);

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'the copy sheet is open');

      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      expect(keyboardIsUp(tester), isTrue);

      // Kotlin's restore is conditional — `if (!viewModel.terminalReadOnly)`. The same round trip
      // on a read-only session must leave the keyboard down, or copying output would be a way to
      // summon a keyboard that read-only exists to suppress (ledger 90).
      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      expect(keyboardIsUp(tester), isFalse);

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      expect(keyboardIsUp(tester), isFalse);
      await finish(tester);
    });

    testWidgets('a trip to another app leaves the keyboard where it was', (tester) async {
      // Kotlin frees the hidden input on `ON_STOP` and re-acquires it on `ON_RESUME`
      // (`ShellScreen.kt:1905`), and its own comment says why: Compose's legacy cursor-anchor path
      // dereferences a torn-down IME session and crashes at draw time. That is a Compose defect
      // being worked around, not a behaviour to reproduce — Flutter reattaches its own IME on
      // resume. This asserts the *outcome* Kotlin's workaround produces, so that porting the
      // workaround itself would show up as the regression it would be: a keyboard that vanishes
      // every time the user checks a notification.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      expect(keyboardIsUp(tester), isTrue);

      // The real sequence, both ways: the framework asserts on a direct paused→resumed jump, since
      // a returning app always passes back through `inactive`.
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }

      expect(keyboardIsUp(tester), isTrue);
      await finish(tester);
    });

    testWidgets('unlocking the app gives the terminal its keyboard back', (tester) async {
      // The lock gate hides the app behind `ExcludeFocus`, which takes the hidden input's focus
      // away — correctly, since a keyboard over the unlock screen would be absurd. Nothing gave it
      // back afterwards: the focus effect's three values are unchanged by locking, so a user who
      // unlocked was returned to a live session that would not accept typing until they tapped the
      // grid. Kotlin re-acquires focus and shows the keyboard on `ON_RESUME`
      // (`ShellScreen.kt:1905`).
      await repo.insertServer(server(name: 'nas'));
      final lock = AppLockController(repo);
      // PBKDF2 yields to the event loop between chunks, and a widget test's fake-async zone never
      // advances it, so both PIN operations have to run in the real one or the test hangs.
      await tester.runAsync(() async {
        await lock.load();
        await lock.setPin('1234');
      });
      await pump(tester, lock: lock);
      await connect(tester);
      expect(keyboardIsUp(tester), isTrue);

      // Single frames, not `pumpAndSettle`: the unlock screen focuses its PIN field, and a focused
      // field blinks its cursor forever, so settling never completes while the app is locked.
      lock.lockNow();
      await tester.pump();
      expect(keyboardIsUp(tester), isFalse, reason: 'no keyboard over the unlock screen');

      final outcome = await tester.runAsync(() => lock.unlockWithPin('1234'));
      expect(outcome, UnlockOutcome.unlocked);
      await tester.pump();
      await tester.pump();

      expect(keyboardIsUp(tester), isTrue);
      await finish(tester);
    });

    testWidgets('tapping a read-only terminal focuses it without summoning the keyboard', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      // Control: a writable session must still raise the keyboard on tap, or this fix would have
      // "passed" by breaking terminal input outright.
      await tester.tap(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();
      expect(keyboardIsUp(tester), isTrue, reason: 'a writable terminal still takes the keyboard');

      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();

      // Input is dropped in read-only mode, so a keyboard here covers the output the user is
      // trying to read in exchange for keystrokes that go nowhere.
      expect(keyboardIsUp(tester), isFalse);
      await finish(tester);
    });

    testWidgets('turning read-only on takes the keyboard away', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      await tester.tap(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();
      expect(keyboardIsUp(tester), isTrue);

      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();

      expect(keyboardIsUp(tester), isFalse);
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

  testWidgets('the terminal grid is readable by a screen reader', (tester) async {
    // Defect 73, end to end. The pure label is unit-tested in terminal_transcript_test.dart; this is
    // the wiring — that it reaches the semantics tree at all, which a painted grid does not do by
    // itself. Without it TalkBack finds nothing on the app's primary screen.
    final handle = tester.ensureSemantics();
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);

    transport.opened.single.emit('uptime\r\n');
    transport.opened.single.emit('load average: 0.14\r\n');
    await tester.pump(const Duration(milliseconds: 30));

    final node = tester.getSemantics(find.byKey(const ValueKey('shell.surface')));
    // `dotAll`, because the label carries the grid's own newlines between rows.
    expect(node.label, matches(RegExp(r'^Terminal output: .*load average: 0\.14', dotAll: true)));
    expect(
      node.flagsCollection.isReadOnly,
      isTrue,
      reason: 'output is not an editable field, and announcing it as one would invite editing',
    );

    handle.dispose();
    await finish(tester);
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

    testWidgets('it opens on the visible screen, not the whole scrollback', (tester) async {
      // Defect 67. Kotlin's long press copies the visible screen and offers the full buffer as a
      // second choice (`ui/ShellScreen.kt:2086` and `:2491`). The port only ever built the full
      // buffer, so the common case — copy the error currently on screen — could not be done, and
      // every long press rendered the entire scrollback into selectable text.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      for (var i = 0; i < 200; i++) {
        transport.opened.single.emit('line $i\r\n');
      }
      await tester.pump(const Duration(milliseconds: 30));

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();

      String shown() =>
          tester.widget<SelectableText>(find.byKey(const ValueKey('transcript.text'))).data!;

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('transcript.title'))).data,
        'Visible screen',
      );
      expect(shown(), contains('line 199'));
      expect(
        shown(),
        isNot(contains('line 0')),
        reason: 'line 0 scrolled off, so it is not on the visible screen',
      );

      await tester.tap(find.byKey(const ValueKey('transcript.toggleRange')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('transcript.title'))).data,
        'Full buffer',
      );
      expect(
        shown(),
        contains('line 0'),
        reason: 'the error that already scrolled past must still be reachable',
      );
      expect(shown(), contains('line 199'));

      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('the scrollback can be cleared, after confirming', (tester) async {
      // Defect 69. TerminalEmulator.clearScrollback() existed but its only caller was the DECSTR
      // escape handler, so there was no way for a user to drop buffered output at all — and with a
      // persistent tmux session, ending the session does not drop it either.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      for (var i = 0; i < 200; i++) {
        transport.opened.single.emit('line $i\r\n');
      }
      await tester.pump(const Duration(milliseconds: 30));

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript.toggleRange')));
      await tester.pumpAndSettle();

      String shown() =>
          tester.widget<SelectableText>(find.byKey(const ValueKey('transcript.text'))).data!;
      expect(shown(), contains('line 0'));

      // Cancelling keeps the buffer: this is not recoverable, so it must not happen by mistake.
      await tester.tap(find.byKey(const ValueKey('transcript.clearScrollback')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript.clear.cancel')));
      await tester.pumpAndSettle();
      expect(shown(), contains('line 0'));

      await tester.tap(find.byKey(const ValueKey('transcript.clearScrollback')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript.clear.confirm')));
      await tester.pumpAndSettle();

      expect(
        shown(),
        isNot(contains('line 0')),
        reason: 'the scrollback is gone, even on the full-buffer range',
      );
      expect(
        shown(),
        contains('line 199'),
        reason: 'the live screen survives — only the scrollback is dropped',
      );

      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('the range can be switched back again', (tester) async {
      // A one-way toggle would trade one missing range for the other.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      for (var i = 0; i < 200; i++) {
        transport.opened.single.emit('line $i\r\n');
      }
      await tester.pump(const Duration(milliseconds: 30));

      await tester.longPress(find.byKey(const ValueKey('shell.surface')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript.toggleRange')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript.toggleRange')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('transcript.title'))).data,
        'Visible screen',
      );
      expect(
        tester.widget<SelectableText>(find.byKey(const ValueKey('transcript.text'))).data!,
        isNot(contains('line 0')),
      );

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

    testWidgets('a second host can be connected straight into a pane', (tester) async {
      // Kotlin loads two *hosts* into panes in one action. The port could only split sessions that
      // were already connected, so putting a second host alongside meant connecting it, watching it
      // take over the screen, and splitting back — and with one session open the split control was
      // hidden entirely, saying "Open a second session first".
      await repo.insertServer(server(name: 'nas'));
      await repo.insertServer(server(name: 'db'));
      await pump(tester);
      await connect(tester);
      expect(vm.sessions, hasLength(1));

      // The control is offered now, because there is a host to put in the second pane.
      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.split.connectHeader')), findsOneWidget);

      // Whichever host the connect flow did not pick — the list order is its business, not this
      // test's.
      final inUse = vm.current!.serverName;
      final other = vm.connectableServers.firstWhere((s) => s.name != inUse);
      await tester.tap(find.byKey(ValueKey('shell.split.connect.${other.id}')));
      await tester.pumpAndSettle();

      expect(vm.sessions, hasLength(2));
      expect(find.byKey(const ValueKey('shell.splitView')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.surface')), findsNWidgets(2));
      expect(
        vm.current?.serverName,
        inUse,
        reason: 'the new host goes alongside the one being used, not in front of it',
      );
      expect(vm.splitSession?.serverName, other.name);
      await finish(tester);
    });

    testWidgets('a host already open is not offered again', (tester) async {
      // It would be offered twice — once as a session, once as a host — and connecting it a second
      // time would open a duplicate terminal to the same machine.
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      expect(
        find.byKey(const ValueKey('shell.split')),
        findsNothing,
        reason: 'the only host is already open, so there is nothing to add',
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

    testWidgets('a screen reader can identify and focus either terminal pane', (tester) async {
      // Kotlin's TerminalPaneFrame gives each pane a label, selected state and an OnClick
      // semantics action. A cyan border is no substitute: without the action a TalkBack user can
      // read both painted terminals but cannot choose which one receives the next command.
      final handle = tester.ensureSemantics();
      await connectTwo(tester);
      final other = vm.splitCandidates.single;
      final firstId = vm.current!.id;
      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shell.split.pick.${other.id}')));
      await tester.pumpAndSettle();

      final firstFinder = find.byKey(ValueKey('shell.pane.$firstId'));
      final secondFinder = find.byKey(ValueKey('shell.pane.${other.id}'));
      final first = tester.getSemantics(firstFinder);
      final second = tester.getSemantics(secondFinder);

      expect(first.label, 'Terminal pane 1: ${vm.current!.serverName}');
      expect(first.value, 'Active terminal pane');
      expect(first.flagsCollection.isSelected, Tristate.isTrue);
      expect(second.label, 'Terminal pane 2: ${other.serverName}');
      expect(second.value, 'Inactive terminal pane');
      expect(second.flagsCollection.isSelected, Tristate.isFalse);
      expect(second.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      // Drive the semantics action itself. A synthesized pointer tap would only prove the terminal
      // surface still handles touch, not that assistive technology can focus the pane.
      tester.platformDispatcher.onSemanticsActionEvent!(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          viewId: tester.view.viewId,
          nodeId: second.id,
        ),
      );
      await tester.pumpAndSettle();

      expect(vm.current!.id, other.id);
      expect(tester.getSemantics(secondFinder).flagsCollection.isSelected, Tristate.isTrue);
      expect(tester.getSemantics(firstFinder).flagsCollection.isSelected, Tristate.isFalse);

      handle.dispose();
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
