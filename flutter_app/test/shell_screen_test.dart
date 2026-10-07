import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsActionEvent, Tristate;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/domain/terminal_key_encoder.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/shell/shell_screen.dart';
import 'package:omniterm/ui/shell_state.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/widgets/app_lock_gate.dart';
import 'package:omniterm/ui/widgets/popup_scroll_behavior.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/platform/session_service.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';
import 'support/fake_session_service.dart';
import 'support/fake_shell_transport.dart';
import 'support/terminal_options_contract.dart';

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
    SessionService? sessionService,
    Size size = const Size(1000, 1400),
    double textScale = 1,
    AppLockController? lock,
    EdgeInsets viewInsets = EdgeInsets.zero,
    ShellState? shellState,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = ShellViewModel(
      app,
      transport: withTransport ? transport : null,
      sessionService: sessionService,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ShellState>(create: (_) => shellState ?? ShellState()),
          ChangeNotifierProvider<ShellViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          scrollBehavior: const PopupScrollBehavior(),
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
              viewInsets: viewInsets,
            ),
            // The real gate, not a stand-in: it is the thing that puts an `ExcludeFocus` over the
            // whole app while locked, which is exactly what the terminal's focus has to survive.
            child: lock == null
                ? Scaffold(
                    body: ShellScreen(
                      compactIme: viewInsets.bottom > 0 && size.width > size.height,
                    ),
                  )
                : AppLockGate(
                    controller: lock,
                    child: Scaffold(
                      body: ShellScreen(
                        compactIme: viewInsets.bottom > 0 && size.width > size.height,
                      ),
                    ),
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

  testWidgets('terminal OPT exposes runtime options and both copy ranges before scrolling', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    expectTerminalOptionsReady(tester);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('runtime Swipe-typing changes input without saving defaults or leaking composition', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    final saved = app.preferences.smartSwipeInput;
    vm.setSmartSwipeRuntime(true);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('shell.input'));
    expect(tester.widget<TextField>(input).enableSuggestions, isTrue);
    await tester.enterText(input, 'hello');
    await tester.pumpAndSettle();
    vm.setSmartSwipeRuntime(false);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(tester.widget<TextField>(input).enableSuggestions, isFalse);
    await tester.enterText(input, 'x');
    await tester.pumpAndSettle();
    expect(transport.opened.single.writes.last, 'x'.codeUnits);
    expect(app.preferences.smartSwipeInput, saved);
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminalOptions.swipe')));
    await tester.pumpAndSettle();
    expect(vm.smartSwipeInput, isTrue);
    expect(app.preferences.smartSwipeInput, saved);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).enableSuggestions, isTrue);
    await finish(tester);
  });

  group('Smart IME parity', () {
    for (final (modifier, previous, committed, expected) in <(String, String, String, List<int>)>[
      ('CTRL', '', 'c', [3]),
      ('ALT', '', 'b', [27, 98]),
      ('SHFT', '', 'c', [67]),
      ('ALT', 'ab', 'a😀b', [27, ...utf8.encode('😀')]),
      ('ALT', '😀b', '😁😀b', [27, ...utf8.encode('😁')]),
    ]) {
      testWidgets('$modifier sends only the inserted input in $committed', (tester) async {
        await repo.insertServer(server(name: 'nas'));
        await pump(tester);
        await connect(tester);
        try {
          vm.setSmartSwipeRuntime(true);
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('shell.input'));
          if (previous.isNotEmpty) {
            await tester.enterText(input, previous);
            await tester.pumpAndSettle();
          }
          transport.opened.single.writes.clear();
          await tester.tap(find.byKey(ValueKey('shell.key.$modifier')));
          await tester.pumpAndSettle();
          await tester.enterText(input, committed);
          await tester.pumpAndSettle();

          expect(transport.opened.single.writes.single, expected);
          expect(vm.hasModifier, isFalse, reason: 'sticky modifiers apply to one input');
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        } finally {
          await finish(tester);
        }
      });
    }

    for (final key in ['↵', 'TAB', '←']) {
      testWidgets('$key clears the mirrored segment before the next input', (tester) async {
        await repo.insertServer(server(name: 'nas'));
        await pump(tester);
        await connect(tester);
        try {
          vm.setSmartSwipeRuntime(true);
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('shell.input'));
          await tester.enterText(input, 'hello');
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('shell.key.$key')));
          await tester.pumpAndSettle();

          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          transport.opened.single.writes.clear();
          await tester.enterText(input, 'x');
          await tester.pumpAndSettle();
          expect(
            transport.opened.single.writes.single,
            [120],
            reason: 'the next input must not erase an obsolete mirrored word',
          );
        } finally {
          await finish(tester);
        }
      });
    }

    testWidgets('read-only clears composition without changing remote text', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      try {
        vm.setSmartSwipeRuntime(true);
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('shell.input'));
        await tester.enterText(input, 'hello');
        await tester.pumpAndSettle();
        transport.opened.single.writes.clear();
        await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
        await tester.pumpAndSettle();
        expect(transport.opened.single.writes, isEmpty);
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
        await tester.pumpAndSettle();
        await tester.enterText(input, 'x');
        await tester.pumpAndSettle();
        expect(transport.opened.single.writes.single, [120]);
      } finally {
        await finish(tester);
      }
    });

    testWidgets('shell-owned input resets composition before another widget frame', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      try {
        vm.setSmartSwipeRuntime(true);
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('shell.input'));
        await tester.enterText(input, 'hello');
        await tester.pumpAndSettle();
        expect(vm.sendKey(TermKey.enter), isTrue);
        expect(
          tester.widget<TextField>(input).controller!.text,
          isEmpty,
          reason: 'an IME event can arrive before the next frame',
        );
        await tester.enterText(input, 'hello');
        await tester.pumpAndSettle();
        expect(vm.typeText('raw'), isTrue);
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      } finally {
        await finish(tester);
      }
    });

    testWidgets('unrelated output preserves a composing word', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      try {
        vm.setSmartSwipeRuntime(true);
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('shell.input'));
        await tester.enterText(input, 'hello');
        await tester.pumpAndSettle();
        transport.opened.single.writes.clear();
        transport.opened.single.emit('unrelated output\r\n');
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, 'hello');
        await tester.enterText(input, 'hello!');
        await tester.pumpAndSettle();
        expect(transport.opened.single.writes.single, [33]);
      } finally {
        await finish(tester);
      }
    });
  });

  testWidgets('clipboard paste reports pending, empty, failure and a changed-pane skip', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    final first = vm.current!;
    final clipboard = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? clipboard.future : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminalOptions.paste')));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminalOptions.progress')), findsOneWidget);
    await vm.connect(vm.server!);
    clipboard.complete({'text': 'must-not-go-to-other-pane'});
    await tester.pumpAndSettle();
    expect(find.text('Paste skipped: the selected terminal changed.'), findsOneWidget);
    expect(transport.opened.first.writes, isEmpty);
    expect(transport.opened.last.writes, isEmpty);
    vm.select(first.id);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminalOptions.paste')));
    await tester.pumpAndSettle();
    expect(find.text('Clipboard has no text to paste'), findsOneWidget);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.getData') {
        throw PlatformException(code: 'fixture', message: 'clipboard unavailable');
      }
      return null;
    });
    await tester.tap(find.byKey(const ValueKey('terminalOptions.paste')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not paste from clipboard:'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('large clipboard paste confirms and cannot redirect after a focus change', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    final first = vm.current!;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': 'x' * 1000} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminalOptions.paste')));
    // The progress indicator is active until the nested confirmation completes.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('shell.pasteConfirm')), findsOneWidget);
    await vm.connect(vm.server!);
    await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
    await tester.pumpAndSettle();
    expect(find.text('Paste skipped: the selected terminal changed.'), findsOneWidget);
    expect(transport.opened.first.writes, isEmpty);
    expect(transport.opened.last.writes, isEmpty);
    vm.select(first.id);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('runtime awake switch waits for platform acknowledgment and exposes retry', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    final platform = Completer<void>();
    var attempts = 0;
    final shell = ShellState(
      keepScreenOnSetter: (_) async {
        attempts++;
        if (attempts == 1) await platform.future;
      },
    );
    await pump(tester, shellState: shell);
    await connect(tester);
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('terminalOptions.awake')));
    await tester.tap(find.byKey(const ValueKey('terminalOptions.awake')));
    await tester.pump();
    expect(shell.showKeepScreenOnWarning, isFalse);
    expect(shell.isSettingKeepScreenOn, isTrue);
    expect(shell.isKeepScreenOnEnabled, isFalse);
    expect(
      tester.widget<SwitchListTile>(find.byKey(const ValueKey('terminalOptions.awake'))).onChanged,
      isNull,
    );
    platform.completeError(StateError('fixture window unavailable'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('keepScreenOn.retry')));
    await tester.tap(find.byKey(const ValueKey('keepScreenOn.retry')));
    await tester.pumpAndSettle();
    expect(shell.isKeepScreenOnEnabled, isTrue);
    expect(shell.keepScreenOnError, isNull);
    expect(attempts, 2);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  for (final size in [const Size(360, 780), const Size(740, 380)]) {
    testWidgets('terminal options keep paste and copy ranges visible at large text in $size', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, size: size, textScale: 2);
      await vm.connect(vm.server!);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.options')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final key in ['paste', 'visible', 'full', 'clear', 'cancel']) {
        expect(find.byKey(ValueKey('terminalOptions.$key')).hitTestable(), findsOneWidget);
      }
      expect(find.text('↓ More below'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('terminalOptions.scroll')),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(find.text('↑ More above'), findsOneWidget);
      expect(find.text('↓ More below'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('terminalOptions.full')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('transcript.title'))).data,
        'Full buffer',
      );
      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });
  }

  testWidgets('clipboard paste reports a transport write failure instead of success', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    transport.opened.single.writeFailure = StateError('fixture write unavailable');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' ? {'text': 'fixture'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminalOptions.paste')));
    await tester.pumpAndSettle();
    expect(find.text('Paste skipped: the terminal did not accept the text.'), findsOneWidget);
    expect(find.textContaining('characters into terminal.'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('menu clear scrollback confirms, preserves cancel and reports completion', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    for (var i = 0; i < 200; i++) {
      transport.opened.single.emit('fixture-history-$i\r\n');
    }
    await tester.pump(const Duration(milliseconds: 50));
    final session = vm.current!;
    expect(session.emulator.scrollbackRowCount(), greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminalOptions.clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(session.emulator.scrollbackRowCount(), greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('terminalOptions.clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(session.emulator.scrollbackRowCount(), 0);
    expect(find.text('Terminal scrollback cleared.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('software-keyboard paste exposes preparation and cancellation', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    await tester.enterText(find.byKey(const ValueKey('shell.input')), 'x' * 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('shell.pasteConfirm')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell.paste.progress')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shell.paste.progress')), findsNothing);
    expect(find.text('Paste cancelled.'), findsOneWidget);
    expect(transport.opened.single.writes, isEmpty);
    await finish(tester);
  });

  testWidgets('Kotlin terminal header shows host identity above session actions', (tester) async {
    final id = await repo.insertServer(server(name: 'nas'));
    await pump(tester, size: const Size(360, 780));
    await connect(tester);
    expect(find.text('TERM'), findsOneWidget);
    expect(find.text('CURRENT'), findsOneWidget);
    expect(find.byKey(ValueKey('shell.host.detail.$id')), findsOneWidget);
    for (final label in ['OPEN', 'BG', 'SPLIT', '🔓 INPUT', '⋮ OPT', 'DISC']) {
      expect(find.text(label), findsOneWidget);
    }
    final host = tester.getRect(find.byKey(const ValueKey('shell.host')));
    final actions = tester.getRect(find.byKey(const ValueKey('shell.header.actions')));
    expect(actions.top, greaterThanOrEqualTo(host.bottom));
    await tester.tap(find.byKey(const ValueKey('shell.options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminalOptions.cancel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminalOptions.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('header and OPEN overflow cues stay usable at large phone text', (tester) async {
    final id = await repo.insertServer(server(name: 'nas'));
    for (var i = 0; i < 12; i++) {
      await repo.upsertPersistentSession(
        PersistentSessionsCompanion.insert(
          tmuxName: 'fixture-menu-$i',
          serverId: id,
          serverName: 'nas',
          createdAt: 1,
          backgroundedAt: 1,
        ),
      );
    }
    await pump(tester, size: const Size(320, 640), textScale: 2);
    await connect(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('shell.disconnect')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shell.open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('↓ More below'), findsOneWidget);
    expect(find.text('↑ More above'), findsNothing);
    await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.text('↑ More above'), findsOneWidget);
    Navigator.pop(tester.element(find.text('↑ More above')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('header follows pane focus without moving either terminal', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await repo.insertServer(server(name: 'pi'));
    await pump(tester);
    await connect(tester);
    final first = vm.current!;
    await vm.connect(app.servers.last);
    vm.splitWith(first.id);
    await tester.pumpAndSettle();
    final pane = find.byKey(ValueKey('shell.pane.${first.id}'));
    final before = tester.getRect(pane);
    vm.focusPane(first.id);
    await tester.pumpAndSettle();
    try {
      expect(find.text('P2'), findsOneWidget);
      expect(find.text('FOCUSED'), findsOneWidget);
      expect(tester.getRect(pane), before);
      vm.toggleCtrl();
      vm.toggleAlt();
      vm.toggleShift();
      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      expect(first.readOnly, isTrue);
      expect(vm.sessions.last.readOnly, isTrue, reason: 'Kotlin protects both terminal panes');
      expect(vm.hasModifier, isFalse, reason: 'read-only mode cancels armed input modifiers');
    } finally {
      await finish(tester);
    }
  });

  testWidgets('read-only can be enabled before connecting and protects new sessions', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    try {
      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      expect(find.text('🔒 VIEW'), findsOneWidget);
      await connect(tester);
      expect(vm.current!.readOnly, isTrue);
      expect(vm.typeText('do not send'), isFalse);
      expect(transport.opened.single.writes, isEmpty);
      await vm.connect(app.servers.single);
      await tester.pumpAndSettle();
      expect(vm.sessions, hasLength(2));
      expect(vm.sessions.every((session) => session.readOnly), isTrue);
      await tester.tap(find.byKey(const ValueKey('shell.readOnly')));
      await tester.pumpAndSettle();
      expect(vm.sessions.every((session) => !session.readOnly), isTrue);
      expect(vm.typeText('allowed'), isTrue);
      expect(transport.opened.last.writes.last, 'allowed'.codeUnits);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('header background keeps SSH live and OPEN restores the same session', (
    tester,
  ) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    final session = vm.current!;
    await tester.tap(find.byKey(const ValueKey('shell.background')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shell.background.confirm')));
    await tester.pumpAndSettle();
    expect(vm.current, isNull);
    expect(vm.sessions, contains(session));
    expect(transport.opened.single.closeCalled, isFalse);
    await tester.tap(find.byKey(const ValueKey('shell.open')));
    await tester.pumpAndSettle();
    expect(find.text('Background sessions'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('shell.session.${session.id}')));
    await tester.pumpAndSettle();
    expect(vm.current, same(session));
    expect(transport.opened, hasLength(1));
    await finish(tester);
  });

  testWidgets('saved tmux resume shows progress with another terminal already open', (
    tester,
  ) async {
    final id = await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await connect(tester);
    await repo.upsertPersistentSession(
      PersistentSessionsCompanion.insert(
        tmuxName: 'saved-work',
        serverId: id,
        serverName: 'nas',
        createdAt: 1,
        backgroundedAt: 0,
      ),
    );
    late Completer<void> gate;
    transport.execAnswers['command -v'] = 'yes';
    transport.execAnswers['has-session'] = 'SSH Error: connection refused';
    final row = (await repo.getPersistentSessions()).single;
    late Future<void> pending;
    await tester.runAsync(() async {
      gate = Completer<void>();
      transport.execGate = gate;
      pending = vm.resume(row);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(vm.isConnecting, isTrue);
    addTearDown(() async {
      await tester.runAsync(() async {
        if (!gate.isCompleted) gate.complete();
        await pending;
        vm.dispose();
      });
    });
    expect(find.byKey(const ValueKey('shell.phase')), findsOneWidget);
    await tester.runAsync(() async {
      gate.complete();
      await pending;
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('shell.active.error')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell.active.retry')), findsOneWidget);
    expect(await repo.getPersistentSessions(), hasLength(1));
    expect(transport.opened, hasLength(1));
  });

  group('background protection', () {
    testWidgets('a refused keep-alive is visible on the Shell and can be dismissed', (
      tester,
    ) async {
      // The view model knowing is not the same as the user knowing. Without this the refusal
      // reached a getter nothing rendered, which is the same silence the fix set out to end.
      final service = FakeSessionService()
        ..result = const SessionServiceResult.failed('ForegroundServiceStartNotAllowed');
      addTearDown(service.dispose);
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await pump(tester, sessionService: service);

      await connect(tester);
      await tester.pumpAndSettle();

      final warning = find.byKey(const ValueKey('shell.backgroundService.warning'));
      expect(warning, findsOneWidget);
      expect(
        tester.widget<Text>(warning).data,
        contains('ForegroundServiceStartNotAllowed'),
        reason: "the platform's reason is the actionable part",
      );

      await tester.tap(find.byKey(const ValueKey('shell.backgroundService.dismiss')));
      await tester.pumpAndSettle();
      expect(warning, findsNothing);
      await finish(tester);
    });

    testWidgets('a platform without the service shows nothing', (tester) async {
      final service = FakeSessionService()..result = const SessionServiceResult.unsupported();
      addTearDown(service.dispose);
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await pump(tester, sessionService: service);

      await connect(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.backgroundService.warning')), findsNothing);
      await finish(tester);
    });
  });

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

      expect(find.text('nas'), findsNWidgets(2));
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

    testWidgets('a forced offline connect keeps its target, failure and retry action', (
      tester,
    ) async {
      final id = await repo.insertServer(server(name: 'offline-nas', status: 'offline'));
      await pump(tester);
      final target = app.servers.singleWhere((item) => item.id == id);
      transport.failure = StateError('Connection refused');

      await vm.connect(target, confirmedOffline: true);
      await tester.pumpAndSettle();

      expect(find.text('offline-nas'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('shell.error')), findsOneWidget);
      expect(find.textContaining('Connection refused'), findsOneWidget);
      expect(
        find.text('Retry'),
        findsOneWidget,
        reason: 'an offline target must not disappear after its real SSH attempt fails',
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

    testWidgets('held navigation repeats and stops on release', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('shell.key.↑'))),
      );
      await tester.pump();
      final writes = transport.opened.single.writes;
      expect(writes.length, 1, reason: 'The first key is sent on press');
      await tester.pump(const Duration(milliseconds: 399));
      expect(writes.length, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(writes.length, 2);
      await tester.pump(const Duration(milliseconds: 120));
      expect(writes.length, 4);
      await pointer.up();
      await tester.pump(const Duration(seconds: 1));
      expect(writes.length, 4, reason: 'No remote input after release');
      expect(writes, everyElement('\x1b[A'.codeUnits));
      await finish(tester);
    });

    testWidgets('moving outside a held key cancels repeat', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('shell.key.⌫'))),
      );
      await tester.pump();
      expect(transport.opened.single.writes.length, 1);
      await pointer.moveBy(const Offset(0, -120));
      await tester.pump(const Duration(seconds: 1));
      expect(transport.opened.single.writes.length, 1);
      await pointer.up();
      await finish(tester);
    });

    testWidgets('backgrounding cancels a held key', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('shell.key.↑'))),
      );
      await tester.pump();
      expect(transport.opened.single.writes.length, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 1));
      expect(transport.opened.single.writes.length, 1);
      await pointer.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await finish(tester);
    });

    testWidgets('normal key bar keeps the inverted T centered across two rows', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester, size: const Size(440, 900));
      await connect(tester);
      Offset center(String key) => tester.getCenter(find.byKey(ValueKey('shell.key.$key')));
      expect(center('↑').dx, center('↓').dx);
      expect(center('↑').dx, 220);
      expect(center('↓').dy - center('↑').dy, 38);
      expect(center('←').dy, center('↓').dy);
      expect(center('→').dy, center('↓').dy);
      expect(center('FN').dx, center('SYM').dx);
      expect(center('SYM').dy - center('FN').dy, 38);
      await finish(tester);
    });

    testWidgets('landscape IME compacts the bar and keeps layer toggles fixed', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(
        tester,
        size: const Size(1000, 400),
        viewInsets: const EdgeInsets.only(bottom: 100),
      );
      await connect(tester);
      Offset center(String key) => tester.getCenter(find.byKey(ValueKey('shell.key.$key')));
      final sym = center('SYM');
      final fn = center('FN');
      expect(center('↑').dy, center('↓').dy);
      expect(center('←').dy, center('→').dy);
      await tester.tap(find.byKey(const ValueKey('shell.key.FN')));
      await tester.pump();
      expect(center('SYM'), sym);
      expect(center('NAV'), fn);
      await tester.tap(find.byKey(const ValueKey('shell.key.SYM')));
      await tester.pump();
      expect(center('SYM'), sym);
      expect(center('FN'), fn);
      await finish(tester);
    });

    testWidgets('rotation with stale IME insets keeps terminal controls reachable', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      // Android briefly reports this height during rotation before the IME sends new insets.
      await pump(tester, size: const Size(440, 74));
      await vm.connect(app.servers.single);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('shell.key.SYM')));
      await tester.pump();
      expect(find.byKey(const ValueKey('shell.key.SYM')).hitTestable(), findsOneWidget);
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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();

      expect(keyboardIsUp(tester), isFalse);
      await finish(tester);
    });

    testWidgets('the software keyboard offers Enter and keeps accepting shell input', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      expect(tester.testTextInput.setClientArgs?['inputAction'], 'TextInputAction.newline');
      tester.testTextInput.updateEditingValue(const TextEditingValue(text: '\n'));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(transport.opened.single.writes.last, [13]);
      expect(keyboardIsUp(tester), isTrue);
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

      expect(find.textContaining('Reconnecting'), findsOneWidget);
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
    testWidgets('switching sessions copies the selected visible screen and its full buffer', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);
      final first = vm.current!;
      for (var i = 0; i < 200; i++) {
        transport.opened.first.emit('FIRST_HOST_LINE_$i\r\n');
      }
      await vm.connect(vm.server!);
      final second = vm.current!;
      for (var i = 0; i < 200; i++) {
        transport.opened.last.emit('SECOND_HOST_LINE_$i\r\n');
      }
      await tester.pump(const Duration(milliseconds: 50));
      for (final (session, own, other) in [
        (first, 'FIRST_HOST', 'SECOND_HOST'),
        (second, 'SECOND_HOST', 'FIRST_HOST'),
        (first, 'FIRST_HOST', 'SECOND_HOST'),
      ]) {
        vm.select(session.id);
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(const ValueKey('shell.surface')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
        await tester.pumpAndSettle();
        String shown() =>
            tester.widget<SelectableText>(find.byKey(const ValueKey('transcript.text'))).data!;
        expect(shown(), contains('${own}_LINE_199'));
        expect(shown(), isNot(contains('${own}_LINE_0\n')));
        expect(shown(), isNot(contains(other)));
        expect(find.byKey(const ValueKey('transcript.copyAll')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('transcript.toggleRange')));
        await tester.pumpAndSettle();
        expect(shown(), contains('${own}_LINE_0\n'));
        expect(shown(), isNot(contains(other)));
        await tester.tap(find.byKey(const ValueKey('transcript.close')));
        await tester.pumpAndSettle();
      }
      await finish(tester);
    });

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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
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
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
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
      await tester.tap(find.byKey(const ValueKey('shell.open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell.newSession')));
      await tester.pumpAndSettle();
    }

    testWidgets('Smart IME parity clears composition when split focus moves and returns', (
      tester,
    ) async {
      await connectTwo(tester);
      try {
        final first = vm.current!;
        final second = vm.splitCandidates.single;
        await tester.tap(find.byKey(const ValueKey('shell.split')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('shell.split.pick.${second.id}')));
        await tester.pumpAndSettle();
        vm.setSmartSwipeRuntime(true);
        await tester.pumpAndSettle();
        Finder inputFor(String id) => find.descendant(
          of: find.byKey(ValueKey('shell.pane.$id')),
          matching: find.byKey(const ValueKey('shell.input')),
        );
        await tester.enterText(inputFor(first.id), 'hello');
        await tester.pumpAndSettle();
        for (final shell in transport.opened) {
          shell.writes.clear();
        }
        await tester.tap(find.byKey(ValueKey('shell.pane.${second.id}')));
        await tester.pumpAndSettle();
        expect(vm.current, same(second));
        await tester.tap(find.byKey(ValueKey('shell.pane.${first.id}')));
        await tester.pumpAndSettle();
        expect(vm.current, same(first));
        expect(tester.widget<TextField>(inputFor(first.id)).controller!.text, isEmpty);
        expect(transport.opened.expand((shell) => shell.writes), isEmpty);
        await tester.enterText(inputFor(first.id), 'x');
        await tester.pumpAndSettle();
        expect(transport.opened.expand((shell) => shell.writes).single, [120]);
      } finally {
        await finish(tester);
      }
    });

    testWidgets('Smart IME parity rejects a late commit from an inactive split pane', (
      tester,
    ) async {
      await connectTwo(tester);
      try {
        final first = vm.current!;
        final second = vm.splitCandidates.single;
        await tester.tap(find.byKey(const ValueKey('shell.split')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('shell.split.pick.${second.id}')));
        await tester.pumpAndSettle();
        vm.setSmartSwipeRuntime(true);
        await tester.pumpAndSettle();
        final input = find.descendant(
          of: find.byKey(ValueKey('shell.pane.${first.id}')),
          matching: find.byKey(const ValueKey('shell.input')),
        );
        final oldCommit = tester.widget<TextField>(input).onChanged!;
        await tester.tap(find.byKey(ValueKey('shell.pane.${second.id}')));
        await tester.pumpAndSettle();
        for (final shell in transport.opened) {
          shell.writes.clear();
        }
        oldCommit('late');
        await tester.pumpAndSettle();
        expect(vm.current, same(second));
        expect(
          transport.opened.expand((shell) => shell.writes),
          isEmpty,
          reason: 'a queued old-pane input must never be redirected to the new pane',
        );
      } finally {
        await finish(tester);
      }
    });

    testWidgets('split remains discoverable and explains when nothing is available', (
      tester,
    ) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await connect(tester);

      expect(
        find.byKey(const ValueKey('shell.split')),
        findsOneWidget,
        reason: 'Kotlin keeps its SPLIT action discoverable',
      );
      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.split.none')), findsOneWidget);
      Navigator.pop(tester.element(find.byKey(const ValueKey('shell.split.none'))));
      await tester.pumpAndSettle();
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
        findsOneWidget,
        reason: 'Kotlin keeps SPLIT visible even when this host is already open',
      );
      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.split.none')), findsOneWidget);
      Navigator.pop(tester.element(find.byKey(const ValueKey('shell.split.none'))));
      await tester.pumpAndSettle();
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

    testWidgets('long pressing an inactive split pane focuses it before opening its transcript', (
      tester,
    ) async {
      await connectTwo(tester);
      final other = vm.splitCandidates.single;
      final firstId = vm.current!.id;
      await tester.tap(find.byKey(const ValueKey('shell.split')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('shell.split.pick.${other.id}')));
      await tester.pumpAndSettle();
      expect(vm.current!.id, firstId);

      final inactiveSurface = find.descendant(
        of: find.byKey(ValueKey('shell.pane.${other.id}')),
        matching: find.byKey(const ValueKey('shell.surface')),
      );
      await tester.longPress(inactiveSurface);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terminalOptions.visible')));
      await tester.pumpAndSettle();

      expect(vm.current!.id, other.id, reason: 'long press must focus the pane it acted on');
      expect(find.byKey(const ValueKey('transcript.title')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transcript.close')));
      await tester.pumpAndSettle();
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

      expect(find.text('⬌ COLS'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell.split.axis')));
      await tester.pumpAndSettle();
      expect(find.text('⬍ STACK'), findsOneWidget, reason: 'Kotlin names the next layout action');

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
