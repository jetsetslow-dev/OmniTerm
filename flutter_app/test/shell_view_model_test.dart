import 'package:omniterm/platform/shortcut_helper.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/data/term/tmux_bootstrap.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/domain/terminal_key_encoder.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';

import 'support/fake_secure_storage.dart';
import 'support/fake_shell_transport.dart';

/// Records what would have been pushed to the launcher, instead of calling the platform.
class _RecordingShortcuts extends ShortcutHelper {
  _RecordingShortcuts() : super(channel: const MethodChannel('omniterm/shortcuts.test'));

  final List<(int, int)> splits = [];

  @override
  Future<bool> pushSplit(Server first, Server second) async {
    splits.add((first.id, second.id));
    return true;
  }
}

/// An [AppRepository] whose persistent-session reads start failing once one has been written.
///
/// That is exactly the window the ownership tests care about: `_persistentTarget` writes the row,
/// the session is built and registered, and only then does `_reloadSaved` read the list back. A
/// failure there is optional bookkeeping failing around a shell that is already live.
class _FailsReadingAfterWriting extends AppRepository {
  _FailsReadingAfterWriting(super.db, super.secrets);

  bool _wrote = false;

  @override
  Future<int> upsertPersistentSession(PersistentSessionsCompanion session) async {
    final id = await super.upsertPersistentSession(session);
    _wrote = true;
    return id;
  }

  @override
  Future<List<PersistentSession>> getPersistentSessions() {
    if (_wrote) throw StateError('fixture storage unavailable');
    return super.getPersistentSessions();
  }
}

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
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await transport.dispose();
    await db.close();
  });

  Server server({
    required String name,
    String status = 'online',
    bool persistent = false,
    String authType = 'password',
    String authKeyAlias = '',
  }) => Server(
    id: 0,
    name: name,
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    serverColor: 'Default',
    authType: authType,
    authPassword: 'pw',
    authKeyAlias: authKeyAlias,
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

  Future<ShellViewModel> start({SshTransport? ssh}) async {
    await app.start();
    // The host list arrives on a drift watch stream, so it is not populated by the time `start`
    // returns; every assertion here is about which host is chosen, so it has to be.
    await Future<void>.delayed(Duration.zero);
    return vm = ShellViewModel(app, transport: ssh ?? transport);
  }

  group('automatic reconnect preserves the terminal', () {
    Future<void> until(bool Function() ready) async {
      await Future<void>(() async {
        while (!ready()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }).timeout(const Duration(seconds: 5));
    }

    test('a socket drop replaces only the channel and keeps scrollback and selection', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!;
      transport.opened.single.emit('before-drop\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await transport.opened.single.dropConnection();
      await until(() => session.reconnecting);
      expect(vm.current, same(session));
      await until(() => transport.opened.length == 2 && session.isOpen);
      expect(vm.current, same(session));
      expect(session.reconnecting, isFalse);
      expect(
        session.emulator.snapshot().rows.expand((r) => r.spans).map((s) => s.text).join(),
        contains('before-drop'),
      );
      expect(vm.typeText('after'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(utf8.decode(transport.opened.last.writes.last), 'after');
    });

    test('backgrounding and switching live tabs never reopen SSH', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      await vm.connect(vm.server!);
      final first = vm.sessions.first;
      for (var i = 0; i < 3; i++) {
        vm.setTerminalVisible(false);
        vm.setTerminalVisible(true);
        vm.select(first.id);
        vm.select(vm.sessions.last.id);
      }
      expect(transport.opened, hasLength(2));
      expect(vm.sessions.every((s) => s.isOpen && !s.reconnecting), isTrue);
      expect(transport.opened.every((s) => !s.closeCalled), isTrue);
    });

    test('tmux reconnect attaches the exact saved session without creating another', () async {
      await repo.insertServer(server(name: 'nas', persistent: true));
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!;
      transport.execAnswers['has-session -t ${session.tmuxName}'] = tmuxSessionPresentMarker;
      await transport.opened.single.dropConnection();
      await until(() => transport.opened.length == 2 && session.isOpen);
      final command = transport.opened.last.writes.map(utf8.decode).join();
      expect(command, contains('attach-session -t ${session.tmuxName}'));
      expect(command, isNot(contains('new-session')));
      expect(vm.current, same(session));
      expect(await repo.getPersistentSessions(), hasLength(1));
    });

    test('confirmed absent tmux stops retrying and never opens an empty shell', () async {
      await repo.insertServer(server(name: 'nas', persistent: true));
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!;
      transport.execAnswers['has-session -t ${session.tmuxName}'] = tmuxSessionAbsentMarker;
      await transport.opened.single.dropConnection();
      await until(() => session.reconnectError != null);
      expect(session.reconnectError, contains('no longer exists'));
      expect(session.reconnecting, isFalse);
      expect(transport.opened, hasLength(1));
      expect(await repo.getPersistentSessions(), isEmpty);
    });

    test('control client detach probes and resumes the still-live tmux session', () async {
      await repo.insertServer(server(name: 'nas', persistent: true));
      await start();
      await vm.connect(vm.server!, controlMode: true);
      final session = vm.current!;
      transport.execAnswers['has-session -t ${session.tmuxName}'] = tmuxSessionPresentMarker;
      transport.opened.single.emit('%exit detached\r\n');
      await until(() => session.endReason != ShellSessionEnd.open);
      expect(session.reconnecting, isTrue);
      await until(() => transport.opened.length == 2 && session.isOpen);
      expect(vm.current, same(session));
      expect(transport.opened.last.writes.map(utf8.decode).join(), contains('attach-session'));
      expect(await repo.getPersistentSessions(), hasLength(1));
    });

    test('a quiet control attach resolves its input pane without waiting for output', () async {
      await repo.insertServer(server(name: 'nas', persistent: true));
      await start();
      await vm.connect(vm.server!, controlMode: true);
      final session = vm.current!;
      transport.streamChunks = ['%9\n'];
      transport.opened.single.onWrite = (command) {
        final body = command.startsWith('display-message') ? '0 0\n' : '';
        transport.opened.single.emit('%begin 1 1 1\n$body%end 1 1 1\n');
      };
      transport.opened.single.emit('%session-changed \$0 quiet\r\n');
      await until(() => session.paneChangeRevision > 0);
      await until(() => session.controlPaneId == '%9');
      await until(() => !session.paneChangePending);
      expect(vm.typeText('x'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(transport.opened.single.writes.map(utf8.decode).join(), contains('send-keys -t %9'));
    });

    test('closing while a reconnect is opening disposes the late replacement', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!;
      transport.gate = Completer<void>();
      await transport.opened.single.dropConnection();
      await until(() => transport.openedWith.length == 2);
      vm.close(session);
      transport.gate!.complete();
      await until(() => transport.opened.length == 2 && transport.opened.last.closeCalled);
      expect(vm.sessions, isEmpty);
    });
  });

  group('the split launcher shortcut', () {
    /// Defect 76. `ShortcutHelper.pushSplit` and its whole native implementation existed, and
    /// nothing ever called it — so the shortcut Kotlin offers whenever two hosts share the screen
    /// (`AppViewModel.kt:1712`) could never appear.
    ///
    /// Assigns the shared `vm` so the suite's teardown disposes it, and waits the same zero delay
    /// `start` does: the host list arrives on a drift watch stream and is not populated when
    /// `app.start()` returns.
    Future<ShellViewModel> startWith({ShortcutHelper? shortcuts}) async {
      await app.start();
      await Future<void>.delayed(Duration.zero);
      return vm = ShellViewModel(app, transport: transport, shortcuts: shortcuts);
    }

    test('splitting offers the pair to the launcher', () async {
      final shortcuts = _RecordingShortcuts();
      await repo.insertServer(server(name: 'nas'));
      await repo.insertServer(server(name: 'db'));
      final model = await startWith(shortcuts: shortcuts);
      for (final host in app.servers) {
        await model.connect(host);
      }

      expect(model.sessions, hasLength(2));
      expect(shortcuts.splits, isEmpty, reason: 'connecting alone is not a split');

      final other = model.sessions.firstWhere((s) => s.id != model.current!.id);
      final currentServerId = model.current!.serverId;
      model.splitWith(other.id);

      expect(shortcuts.splits, hasLength(1));
      expect(
        shortcuts.splits.single,
        (currentServerId, other.serverId),
        reason: 'the pair is recorded in pane order, so the shortcut reopens the same layout',
      );
    });

    test('with no launcher support, no shortcut and no failure', () async {
      // Every other ShortcutHelper action degrades this way; failing to offer a shortcut must never
      // interrupt opening a terminal.
      await repo.insertServer(server(name: 'nas'));
      await repo.insertServer(server(name: 'db'));
      final model = await startWith();
      for (final host in app.servers) {
        await model.connect(host);
      }
      final other = model.sessions.firstWhere((s) => s.id != model.current!.id);

      expect(() => model.splitWith(other.id), returnsNormally);
      expect(model.splitSession?.id, other.id);
    });
  });

  String sent(FakeShellTransport t) =>
      t.opened.last.writes.map((b) => utf8.decode(b, allowMalformed: true)).join();

  group('which host the screen is about', () {
    test('offers only online hosts for a new connection', () async {
      await repo.insertServer(server(name: 'up'));
      await repo.insertServer(server(name: 'down', status: 'offline'));
      await start();

      expect(vm.connectableServers.map((s) => s.name), ['up']);
      // Forcing SSH to an offline host is done from the Hosts tab, which warns first. Offering it
      // here as an ordinary choice would route around that warning.
      expect(vm.server!.name, 'up');
    });

    test('with a session open, the header names that session\'s host', () async {
      await repo.insertServer(server(name: 'a'));
      await repo.insertServer(server(name: 'b'));
      await start();

      await vm.connect(vm.connectableServers.firstWhere((s) => s.name == 'b'));

      expect(vm.server!.name, 'b', reason: 'the header must name the terminal on screen');
    });
  });

  group('connecting', () {
    test('opens a shell and makes it current', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();

      await vm.connect(vm.server!);

      expect(vm.sessions, hasLength(1));
      expect(vm.current!.serverName, 'nas');
      expect(vm.isConnecting, isFalse);
      expect(vm.error, isNull);
    });

    test('opens at the measured grid rather than a default', () async {
      // A shell opened at 80x24 and resized afterwards makes every prompt redraw and leaves a
      // full-screen app briefly wrong.
      await repo.insertServer(server(name: 'nas'));
      await start();
      vm.rememberGrid(132, 43);

      await vm.connect(vm.server!);

      expect(transport.openSizes.single, (132, 43));
    });

    test('reports the transport phase while it works', () async {
      await repo.insertServer(server(name: 'nas'));
      transport = FakeShellTransport(phases: ['Authenticating…'])..gate = Completer<void>();
      await start();

      final pending = vm.connect(vm.server!);
      await Future<void>.delayed(Duration.zero);

      expect(vm.isConnecting, isTrue);
      expect(vm.connectPhase, 'Authenticating…');

      transport.gate!.complete();
      await pending;
      expect(vm.connectPhase, isNull);
    });

    test('a credential problem is reported in the user\'s terms, not as a stack trace', () async {
      await repo.insertServer(server(name: 'nas', authType: 'key', authKeyAlias: 'gone'));
      await start();

      await vm.connect(vm.server!);

      expect(vm.sessions, isEmpty);
      expect(vm.error, contains('gone'));
      expect(vm.error, isNot(contains('Exception')));
    });

    test('without a transport it says the terminal is unavailable', () async {
      // Convention 4: a disabled feature says so rather than opening a screen that will never
      // receive a byte.
      await repo.insertServer(server(name: 'nas'));
      await app.start();
      await Future<void>.delayed(Duration.zero);
      vm = ShellViewModel(app);

      expect(vm.canConnect, isFalse);
      await vm.connect(vm.server!);

      expect(vm.sessions, isEmpty);
      expect(vm.error, contains('no SSH transport'));
    });

    test('an out-of-range scrollback setting is clamped, not obeyed', () async {
      // The same bound the Settings screen enforces, applied again on read: the stored value is not
      // trusted, because a corrupt or hand-edited row must not decide how much memory the terminal
      // takes. The floor is asserted here because it is cheap to observe; the ceiling — which is
      // what stops a two-million-line buffer exhausting the device — is the same clamp.
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('terminal_scrollback_limit', '1');
      await start();

      await vm.connect(vm.server!);
      final session = vm.current!;
      for (var i = 0; i < 700; i++) {
        transport.opened.last.emit('line \$i\r\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(session.emulator.trimmedRowCount, greaterThan(0), reason: 'a limit is in force');
      expect(
        session.emulator.scrollbackRowCount(),
        PreferenceLimits.terminalScrollback.min,
        reason: 'the stored 1 was raised to the floor, not obeyed',
      );
    });

    test('lowering the scrollback limit takes effect on a running session', () async {
      // The defect: the setting was read only when *building* a session, so lowering it to reclaim
      // memory did nothing to the sessions already holding it. Reconnecting was the only way to get
      // the effect — the opposite of what someone reaching for that setting wants.
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('terminal_scrollback_limit', '5000');
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!;
      for (var i = 0; i < 2500; i++) {
        transport.opened.last.emit('line \$i\r\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final before = session.emulator.scrollbackRowCount();
      expect(before, greaterThan(PreferenceLimits.terminalScrollback.min));

      app.applyPreferences(
        app.preferences.copyWith(terminalScrollbackLimit: PreferenceLimits.terminalScrollback.min),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        session.emulator.scrollbackRowCount(),
        PreferenceLimits.terminalScrollback.min,
        reason: 'the buffer was trimmed to the new limit, not left as it was',
      );
    });

    test('raising the limit does not discard what is already there', () async {
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('terminal_scrollback_limit', '2000');
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!;
      for (var i = 0; i < 300; i++) {
        transport.opened.last.emit('line \$i\r\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final before = session.emulator.scrollbackRowCount();

      app.applyPreferences(app.preferences.copyWith(terminalScrollbackLimit: 20000));
      await Future<void>.delayed(Duration.zero);

      expect(session.emulator.scrollbackRowCount(), before);
    });
  });

  group('input', () {
    test('a special key is encoded and sent', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);

      expect(vm.sendKey(TermKey.up), isTrue);
      expect(sent(transport), '[A');
    });

    test('a modifier applies to exactly one key, then clears', () async {
      // A latch the user has to remember to turn off makes the next `l` a screen-clearing ^L.
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);

      vm.toggleCtrl();
      expect(vm.ctrl, isTrue);
      vm.typeText('c');
      expect(vm.ctrl, isFalse);
      vm.typeText('c');

      expect(transport.opened.last.writes.first, [0x03]);
      expect(transport.opened.last.writes.last, 'c'.codeUnits);
    });

    test('a paste is one write and ignores a stuck modifier', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      vm.toggleCtrl();

      vm.paste('echo one\necho two');

      expect(transport.opened.last.writes, hasLength(1), reason: 'contiguous');
      expect(sent(transport), 'echo one\recho two');
      expect(vm.ctrl, isTrue, reason: 'the modifier still belongs to the next keystroke');
    });

    test('a paste is bracketed once the remote turns DECSET 2004 on', () async {
      // The defect this covers is the wiring, not the payload: the emulator tracked the mode and
      // nothing asked it, so a multi-line paste ran line by line on a shell that had explicitly
      // asked for it to arrive as text. Driven through the emulator rather than by setting a flag,
      // because "the remote enabled it" is the only way this is ever true in the app.
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);

      transport.opened.last.emit('[?2004h');
      await Future<void>.delayed(Duration.zero);

      vm.paste('echo one\necho two\n');

      expect(sent(transport), '[200~echo one\recho two[201~\r');
    });

    test('a paste is plain again once the remote turns it off', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);

      transport.opened.last.emit('[?2004h');
      await Future<void>.delayed(Duration.zero);
      transport.opened.last.emit('[?2004l');
      await Future<void>.delayed(Duration.zero);

      vm.paste('echo one\n');

      expect(sent(transport), 'echo one\r');
    });

    group('persistent tmux scrollback', () {
      /// Scrolls the session up so it is no longer following the tail, then delivers output — the
      /// exact condition tmux collapses, and the only one in which a capture is worth its round
      /// trip.
      Future<void> scrollUpWithOutputPending(ShellSession session) async {
        // Enough output to have a history to scroll into: an empty buffer clamps `scrollBy` to the
        // tail, so the session never stops following it and nothing is ever pending.
        for (var i = 0; i < 60; i++) {
          transport.opened.last.emit('line $i\r\n');
        }
        // `emit` publishes on a stream, so the emulator has not seen any of that until the
        // listener runs — scrolling before it does would clamp against an empty buffer.
        await Future<void>.delayed(Duration.zero);

        session.scrollBy(-5);
        transport.opened.last.emit('a burst the client did not keep up with\r\n');
        await Future<void>.delayed(Duration.zero);
      }

      test('scrollback the client never received is fetched and adopted', () async {
        // The defect: tmux does not stream every line to an attached client, so rows the user never
        // had on screen are simply missing locally and are not recoverable from this side. Kotlin
        // fetches them from the pane (`ui/AppViewModel.kt:4967`); this port did not fetch them at
        // all, so scrolling up after a reattach showed only what tmux had replayed.
        await repo.insertServer(server(name: 'nas', persistent: true));
        await start();
        await vm.connect(vm.server!);
        final session = vm.current!;
        // Longer than what the client holds locally, which is the case that matters: the pane knows
        // rows this client never received.
        transport.streamChunks = [List.generate(90, (i) => 'pane-history-$i').join('\n')];

        await scrollUpWithOutputPending(session);
        expect(
          session.scrollbackDirty,
          isTrue,
          reason: 'output while scrolled up may have been collapsed',
        );

        final delta = await vm.resyncTmuxScrollback(session);

        expect(transport.commands.last, contains('capture-pane'));
        expect(delta, greaterThan(0), reason: 'the pane held more rows than the client did');
        expect(session.scrollbackDirty, isFalse);

        // The rows themselves, not just a count. The adoption replaces the scrollback wholesale —
        // Kotlin does the same — so the point is that what the client never received is now there.
        final text = session.emulator
            .snapshot()
            .rows
            .map((r) => r.spans.map((sp) => sp.text).join())
            .join('\n');
        expect(text, contains('pane-history-0'));
        expect(text, contains('pane-history-89'));
      });

      test('a pane change is resolved by asking tmux, over the side channel', () async {
        // Kotlin resolves the active pane with an exec rather than through the control
        // conversation (`data/RemoteParsers.kt:202`), so the query is answerable while the control
        // stream is mid-burst.
        await repo.insertServer(server(name: 'nas', persistent: true));
        await start();
        await vm.connect(vm.server!, controlMode: true);
        final session = vm.current!;
        expect(session.controlMode, isTrue, reason: 'the guard under test only applies here');
        transport.streamChunks = ['%9\n'];
        transport.opened.last.onWrite = (command) {
          final body = command.startsWith('capture-pane')
              ? 'quiet pane\n'
              : command.startsWith('display-message')
              ? '0 0\n'
              : '';
          transport.opened.last.emit('%begin 1 1 1\n$body%end 1 1 1\n');
        };

        expect(await vm.refreshControlActivePane(session), isTrue);

        expect(transport.commands.last, contains("display-message -p -t"));
        expect(transport.commands.last, contains("'#{pane_id}'"));
        expect(session.controlPaneId, '%9');
        expect(session.snapshot.rows.map((row) => row.text).join('\n'), contains('quiet pane'));
        expect(
          session.scrollbackDirty,
          isTrue,
          reason: 'the new pane has history this client has never seen',
        );
      });

      test('an answer that is not a pane id is refused rather than addressed', () async {
        // The query ends in `|| true`, so a tmux that has gone away answers with an empty string.
        // Adopting it would point send-keys at nothing and silently swallow every keystroke.
        await repo.insertServer(server(name: 'nas', persistent: true));
        await start();
        await vm.connect(vm.server!, controlMode: true);
        final session = vm.current!;
        transport.streamChunks = [''];

        expect(await vm.refreshControlActivePane(session), isFalse);
        expect(session.controlPaneId, isNull);
      });

      test('a session that is not persistent is never captured', () async {
        // The round trip is only meaningful for a tmux pane. An ordinary PTY has no server-side
        // history to fetch, and asking for one would be a command per scroll gesture.
        await repo.insertServer(server(name: 'nas'));
        await start();
        await vm.connect(vm.server!);
        final session = vm.current!;
        final before = transport.commands.length;

        await scrollUpWithOutputPending(session);
        expect(await vm.resyncTmuxScrollback(session), 0);

        expect(transport.commands.length, before, reason: 'no command may be sent');
      });

      test('an empty capture leaves the flag armed, so a later scroll retries', () async {
        // Empty is the `#{alternate_on}` guard firing: a TUI owns the pane, and its frames are not
        // history. Clearing the flag here would mean never re-syncing once the TUI exits.
        await repo.insertServer(server(name: 'nas', persistent: true));
        await start();
        await vm.connect(vm.server!);
        final session = vm.current!;
        transport.streamChunks = [''];

        await scrollUpWithOutputPending(session);
        expect(await vm.resyncTmuxScrollback(session), 0);

        expect(session.scrollbackDirty, isTrue);
      });
    });

    test('read-only refuses typing but still allows paging', () async {
      // Paging only moves the local viewport; it never reaches the remote.
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      final session = vm.current!..setReadOnly(true);
      for (var i = 0; i < 60; i++) {
        transport.opened.last.emit('line $i\r\n');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(vm.typeText('rm -rf /'), isFalse);
      expect(vm.sendKey(TermKey.enter), isFalse);
      expect(transport.opened.last.writes, isEmpty);

      expect(vm.sendKey(TermKey.pageUp), isTrue);
      expect(session.followTail, isFalse);
      expect(transport.opened.last.writes, isEmpty, reason: 'paging is local');
    });

    test('nothing is sent when there is no session', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();

      expect(vm.sendKey(TermKey.enter), isFalse);
      expect(vm.typeText('x'), isFalse);
    });
  });

  group('session list', () {
    test('closing one selects another rather than leaving nothing focused', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      final first = vm.sessions.first;
      await vm.connect(vm.server!);

      vm.close(vm.current!);

      expect(vm.sessions, hasLength(1));
      expect(vm.current!.id, first.id);
    });

    test('a session that ended keeps its place until it is dismissed', () async {
      // Its scrollback is the only record of why it died.
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);
      await transport.opened.last.dropConnection();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(vm.sessions, hasLength(1));
      expect(vm.current!.endReason, ShellSessionEnd.disconnected);

      vm.dismissEnded(vm.current!);
      expect(vm.sessions, isEmpty);
    });

    test('dismissing does nothing to a live session', () async {
      await repo.insertServer(server(name: 'nas'));
      await start();
      await vm.connect(vm.server!);

      vm.dismissEnded(vm.current!);

      expect(vm.sessions, hasLength(1));
    });
  });

  group('persistent sessions', () {
    test('an ordinary host is not put inside tmux', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas'));
      await Future<void>.delayed(Duration.zero);

      await vm.connect((await repo.getAllServers()).single);

      expect(sent(transport), isEmpty, reason: 'nothing should be typed into a plain shell');
      expect(await repo.getPersistentSessions(), isEmpty);
    });

    test('a persistent host is put inside a named tmux session', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);

      await vm.connect((await repo.getAllServers()).single);

      final command = sent(transport);
      expect(command, contains('new-session -d -s'));
      expect(command, contains('exec tmux attach-session'));
      // Guarded, so a host without tmux is left at an ordinary prompt rather than a broken one.
      expect(command, startsWith('command -v tmux'));

      final saved = await repo.getPersistentSessions();
      expect(saved, hasLength(1));
      expect(saved.single.serverName, 'nas');
    });

    test('reconnecting re-attaches instead of starting a second session', () async {
      // This is the difference between persistence and merely "runs tmux": a host that starts a
      // fresh session on every reconnect has lost the work the user came back for.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      final host = (await repo.getAllServers()).single;

      await vm.connect(host);
      final name = (await repo.getPersistentSessions()).single.tmuxName;
      transport.execAnswers['has-session -t $name'] = tmuxSessionPresentMarker;

      await vm.connect(host);
      final second = sent(transport);

      expect(second, contains('has-session -t $name'));
      expect(second, contains('attach-session -t $name'));
      expect(second, isNot(contains('new-session -d -s $name')));
      expect(
        await repo.getPersistentSessions(),
        hasLength(1),
        reason: 'the same name is resumed, not duplicated',
      );
    });

    test('an open session is not offered as resumable', () async {
      // Offering to resume the terminal the user is looking at would be nonsense.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);

      await vm.connect((await repo.getAllServers()).single);

      expect(await repo.getPersistentSessions(), hasLength(1));
      expect(vm.resumableSessions, isEmpty, reason: 'it is open in a tab');
    });

    test('a session left running is offered once its tab is closed', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      await vm.connect((await repo.getAllServers()).single);

      vm.close(vm.sessions.single);
      await Future<void>.delayed(Duration.zero);

      expect(vm.resumableSessions, hasLength(1));
      expect(vm.resumableSessions.single.serverName, 'nas');
    });

    test(
      'leaving resumable finishes saving recovery metadata before reporting completion',
      () async {
        final transport = FakeShellTransport();
        final vm = await start(ssh: transport);
        await repo.insertServer(server(name: 'nas', persistent: true));
        await Future<void>.delayed(Duration.zero);
        await vm.connect((await repo.getAllServers()).single);
        final name = vm.current!.tmuxName;
        await Future.sync(vm.leaveOrBackgroundAll);
        expect(vm.sessions, isEmpty);
        expect(vm.resumableSessions.single.tmuxName, name);
        expect(vm.resumableSessions.single.backgroundedAt, greaterThan(0));
      },
    );

    test(
      'a missing recovery record keeps the live tab open and reports the leave failure',
      () async {
        final transport = FakeShellTransport();
        final vm = await start(ssh: transport);
        await repo.insertServer(server(name: 'nas', persistent: true));
        await Future<void>.delayed(Duration.zero);
        await vm.connect((await repo.getAllServers()).single);
        final session = vm.current!;
        await repo.deletePersistentSession(session.tmuxName!);
        expect(await vm.leaveResumable(session), isFalse);
        expect(vm.current, same(session));
        expect(session.isOpen, isTrue);
        expect(vm.error, contains('tab was kept open'));
        expect(vm.isLeavingSessions, isFalse);
      },
    );

    test('a later recovery write failure keeps every tab open and rolls back the batch', () async {
      await start();
      await repo.insertServer(server(name: 'first', persistent: true));
      await repo.insertServer(server(name: 'second', persistent: true));
      await Future<void>.delayed(Duration.zero);
      for (final host in await repo.getAllServers()) {
        await vm.connect(host);
      }
      final sessions = vm.sessions.toList();
      expect(sessions, hasLength(2));
      final before = await repo.getPersistentSessions();
      final rejected = sessions.last.tmuxName!.replaceAll("'", "''");
      await db.customStatement(
        "CREATE TRIGGER reject_leave BEFORE INSERT ON persistent_sessions "
        "WHEN NEW.tmuxName = '$rejected' BEGIN SELECT RAISE(ABORT, 'fixture storage unavailable'); END",
      );
      try {
        expect(await vm.leaveOrBackgroundAll(), isFalse);
        expect(vm.sessions, orderedEquals(sessions));
        expect(sessions.every((session) => session.isOpen), isTrue);
        expect(vm.error, contains('fixture storage unavailable'));
        final after = await repo.getPersistentSessions();
        for (final row in before) {
          expect(
            after.singleWhere((saved) => saved.tmuxName == row.tmuxName).backgroundedAt,
            row.backgroundedAt,
          );
        }
      } finally {
        await db.customStatement('DROP TRIGGER reject_leave');
      }
      expect(await vm.leaveOrBackgroundAll(), isTrue);
      expect(vm.sessions, isEmpty);
      expect(vm.resumableSessions, hasLength(2));
      expect(vm.error, isNull);
      for (final row in before) {
        expect(
          vm.resumableSessions.singleWhere((saved) => saved.tmuxName == row.tmuxName).createdAt,
          row.createdAt,
        );
      }
    });

    test('a failed tmux termination never forgets the remote recovery pointer', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      await vm.connect((await repo.getAllServers()).single);
      final session = vm.current!;
      transport.execAnswers['kill-session'] = 'SSH Error: connection lost';
      await vm.terminate(session);
      expect((await repo.getPersistentSessions()).single.tmuxName, session.tmuxName);
      expect(vm.error, contains('could not be confirmed stopped'));
    });

    test(
      'termination forgets only a session confirmed absent and clears the resumable list',
      () async {
        final transport = FakeShellTransport();
        final vm = await start(ssh: transport);
        await repo.insertServer(server(name: 'nas', persistent: true));
        await Future<void>.delayed(Duration.zero);
        await vm.connect((await repo.getAllServers()).single);
        final session = vm.current!;
        transport.execAnswers['kill-session'] = '';
        transport.execAnswers['has-session -t ${session.tmuxName}'] = tmuxSessionAbsentMarker;
        await vm.terminate(session);
        expect(await repo.getPersistentSessions(), isEmpty);
        expect(vm.resumableSessions, isEmpty);
        expect(vm.sessions, isEmpty);
        expect(vm.error, isNull);
      },
    );

    test('an ambiguous post-termination probe keeps the recovery entry', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      await vm.connect((await repo.getAllServers()).single);
      final session = vm.current!;
      transport.execAnswers['kill-session'] = '';
      transport.execAnswers['has-session -t ${session.tmuxName}'] = 'SSH Error: timed out';
      await vm.terminate(session);
      expect((await repo.getPersistentSessions()).single.tmuxName, session.tmuxName);
      expect(vm.error, contains('could not be confirmed stopped'));
    });

    test('closing a tab starts the left-running clock', () async {
      // The whole point of a persistent host is that closing the tab does not end the work — so the
      // moment it stops being watched is the only thing that makes the resumable list actionable.
      // Without it every row reads as having been abandoned in 1970.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      await vm.connect((await repo.getAllServers()).single);

      final before = (await repo.getPersistentSessions()).single;
      expect(before.backgroundedAt, 0, reason: 'still being watched');

      final closedAt = DateTime.now().millisecondsSinceEpoch;
      vm.close(vm.sessions.single);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final after = (await repo.getPersistentSessions()).single;
      expect(after.backgroundedAt, greaterThanOrEqualTo(closedAt));
      expect(after.tmuxName, before.tmuxName, reason: 'the same row, not a second one');
      expect(after.serverId, before.serverId);
      expect(after.createdAt, before.createdAt, reason: 'when it started is not when it was left');
    });

    test('a non-persistent host has no clock to start', () async {
      // Closing an ordinary shell ends it. There is no row, and nothing to stamp.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'plain'));
      await Future<void>.delayed(Duration.zero);
      await vm.connect((await repo.getAllServers()).single);

      vm.close(vm.sessions.single);
      await Future<void>.delayed(Duration.zero);

      expect(await repo.getPersistentSessions(), isEmpty);
    });

    test('resuming attaches to that exact session, not the newest one', () async {
      // The list exists so a specific session can be reached; joining whichever row happened to be
      // last would make picking one meaningless.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      await repo.upsertPersistentSession(
        PersistentSessionsCompanion.insert(
          tmuxName: 'omniterm-1-older',
          serverId: 1,
          serverName: 'nas',
          createdAt: 1,
          backgroundedAt: 0,
        ),
      );
      await repo.upsertPersistentSession(
        PersistentSessionsCompanion.insert(
          tmuxName: 'omniterm-1-newer',
          serverId: 1,
          serverName: 'nas',
          createdAt: 2,
          backgroundedAt: 0,
        ),
      );
      await vm.refreshResumable();
      transport.execAnswers['has-session -t omniterm-1-older'] = tmuxSessionPresentMarker;

      await vm.resume(vm.resumableSessions.firstWhere((r) => r.tmuxName == 'omniterm-1-older'));

      expect(sent(transport), contains('attach-session -t omniterm-1-older'));
      expect(sent(transport), isNot(contains('omniterm-1-newer')));
    });

    test('resume keeps tmux identity even after the host default changes to plain SSH', () async {
      await repo.insertServer(server(name: 'nas', persistent: false));
      await repo.upsertPersistentSession(
        PersistentSessionsCompanion.insert(
          tmuxName: 'omniterm-kept-default-changed',
          serverId: 1,
          serverName: 'nas',
          createdAt: 1,
          backgroundedAt: 2,
        ),
      );
      await start();
      await vm.refreshResumable();
      transport.execAnswers['has-session -t omniterm-kept-default-changed'] =
          tmuxSessionPresentMarker;
      vm.useControlMode = true;
      await vm.resume(vm.resumableSessions.single);
      expect(vm.current!.tmuxName, 'omniterm-kept-default-changed');
      expect(vm.current!.controlMode, isTrue);
      expect(sent(transport), contains('tmux -C attach-session -t omniterm-kept-default-changed'));
      expect(sent(transport), isNot(contains('new-session')));
    });

    test('forgetting removes the pointer and says the server keeps running it', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: 'nas', persistent: true));
      await Future<void>.delayed(Duration.zero);
      await vm.connect((await repo.getAllServers()).single);
      final row = (await repo.getPersistentSessions()).single;

      await vm.forgetResumable(row);

      expect(await repo.getPersistentSessions(), isEmpty);
      // Nothing was sent to the remote: forgetting is a local act, which is why the button is not
      // called "Close".
      expect(sent(transport), isNot(contains('kill-session')));
    });

    test('resuming a session whose host is gone says so', () async {
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.upsertPersistentSession(
        PersistentSessionsCompanion.insert(
          tmuxName: 'orphan',
          serverId: 99,
          serverName: 'deleted',
          createdAt: 1,
          backgroundedAt: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.refreshResumable();

      await vm.resume(vm.resumableSessions.single);

      expect(vm.error, contains('no longer saved'));
    });

    test(
      'an unreachable resume keeps the recovery row and explains that it can be retried',
      () async {
        await repo.insertServer(server(name: 'nas', persistent: true));
        await repo.upsertPersistentSession(
          PersistentSessionsCompanion.insert(
            tmuxName: 'omniterm-1-kept',
            serverId: 1,
            serverName: 'nas',
            createdAt: 1,
            backgroundedAt: 2,
          ),
        );
        final transport = FakeShellTransport()
          ..execAnswers['command -v tmux'] = 'yes'
          ..execAnswers['has-session -t omniterm-1-kept'] = 'SSH Error: No route to host';
        final model = await start(ssh: transport);
        await model.refreshResumable();

        await model.resume(model.resumableSessions.single);

        expect(await repo.getPersistentSessions(), hasLength(1));
        expect(transport.opened, isEmpty);
        expect(model.error, contains('recovery entry was kept'));
      },
    );

    test(
      'only a confirmed missing tmux session removes the recovery row, with a warning',
      () async {
        await repo.insertServer(server(name: 'nas', persistent: true));
        await repo.upsertPersistentSession(
          PersistentSessionsCompanion.insert(
            tmuxName: 'omniterm-1-gone',
            serverId: 1,
            serverName: 'nas',
            createdAt: 1,
            backgroundedAt: 2,
          ),
        );
        final transport = FakeShellTransport()
          ..execAnswers['command -v tmux'] = 'yes'
          ..execAnswers['has-session -t omniterm-1-gone'] = tmuxSessionAbsentMarker;
        final model = await start(ssh: transport);
        await model.refreshResumable();

        await model.resume(model.resumableSessions.single);

        expect(await repo.getPersistentSessions(), isEmpty);
        expect(transport.opened, isEmpty);
        expect(model.error, contains('tmux confirmed'));
        expect(model.error, contains('no empty replacement'));
      },
    );

    test('the tmux name never carries anything a shell would act on', () async {
      // The name is interpolated into a command the *remote* runs. It is derived from the host id
      // and a timestamp, but the sanitiser is what makes that safe rather than the derivation.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(server(name: r'evil; rm -rf ~ $(id)', persistent: true));
      await Future<void>.delayed(Duration.zero);

      await vm.connect((await repo.getAllServers()).single);

      final command = sent(transport);
      expect(command, isNot(contains('rm -rf')));
      expect(command, isNot(contains(r'$(')));
      expect(RegExp(r'-s ([A-Za-z0-9-]+) ').hasMatch(command), isTrue);
    });
  });

  /// tmux availability on a persistent host, ported from `TmuxInstallDialog` and
  /// `installTmuxAndConnect` (`ui/AppUi.kt:617`, `ui/AppViewModel.kt:5911`).
  ///
  /// Flutter connected regardless: the bootstrap command guards itself with `command -v tmux`, so a
  /// host configured for persistent sessions but missing tmux quietly opened an ordinary shell. The
  /// user believed their work survived a dropped link, and it did not.
  /// Who owns the SSH channel between `openShell` returning it and a `ShellSession` taking it.
  /// Disconnect all, which is seconds of SSH work over however many hosts are open.
  group('disconnect all', () {
    Server persistent({required String name}) =>
        server(name: name, persistent: true).copyWith(persistentSession: true);

    test('every host that could not be stopped survives into the message', () async {
      // The defect: `terminate` wrote straight to `_error`, so in a loop the second failure
      // overwrote the first. A user disconnecting three hosts saw one message and had no idea the
      // others were still running on their servers.
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'yes';
      await repo.insertServer(persistent(name: 'alpha'));
      await repo.insertServer(persistent(name: 'beta'));
      final vm = await start(ssh: ssh);
      for (final host in vm.connectableServers) {
        await vm.connect(host);
      }
      expect(vm.sessions, hasLength(2));
      // Both kills fail: `exec` returns the error rather than throwing, as the real transport does.
      ssh.execAnswers['kill-session'] = 'SSH Error: host unreachable';

      await vm.disconnectAll();

      expect(vm.error, contains('alpha'), reason: 'the first failure must not be overwritten');
      expect(vm.error, contains('beta'));
      expect(vm.error, contains('2 sessions'));
    });

    test('it reports being busy, and refuses to start twice', () async {
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'yes'
        ..execAnswers['kill-session'] = 'ok'
        ..execAnswers['has-session'] = tmuxSessionAbsentMarker;
      await repo.insertServer(persistent(name: 'alpha'));
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);
      expect(vm.isDisconnectingAll, isFalse);

      ssh.execGate = Completer<void>();
      final first = vm.disconnectAll();
      await pumpEventQueue();
      expect(vm.isDisconnectingAll, isTrue, reason: 'seconds of work must show that it is working');

      final second = vm.disconnectAll();
      ssh.execGate!.complete();
      await Future.wait([first, second]);

      expect(vm.isDisconnectingAll, isFalse);
      expect(
        ssh.commands.where((c) => c.contains('kill-session')),
        hasLength(1),
        reason: 'a second run while the first is in flight would kill twice',
      );
    });

    test('a clean disconnect leaves no error behind', () async {
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'yes'
        ..execAnswers['kill-session'] = 'ok'
        ..execAnswers['has-session'] = tmuxSessionAbsentMarker;
      await repo.insertServer(persistent(name: 'alpha'));
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);

      await vm.disconnectAll();

      expect(vm.error, isNull);
      expect(vm.sessions, isEmpty);
    });
  });

  group('channel ownership during connect', () {
    Server persistentHost() => server(name: 'nas', persistent: true);

    test('a persistence failure closes the channel it opened', () async {
      // The defect: `_persistentTarget` does real database work *after* the shell is open. When it
      // threw, the exception unwound straight past the channel — not in `_sessions`, invisible to
      // the user, and holding a shell on the server until the process died.
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'yes';
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      await db.customStatement(
        'CREATE TRIGGER reject_persist BEFORE INSERT ON persistent_sessions '
        "BEGIN SELECT RAISE(ABORT, 'fixture storage unavailable'); END",
      );

      await vm.connect(vm.connectableServers.single);

      expect(ssh.opened, hasLength(1), reason: 'the shell really was opened before the failure');
      expect(
        ssh.opened.single.closeCalled,
        isTrue,
        reason: 'an unowned channel must not be left open on the server',
      );
      expect(vm.sessions, isEmpty, reason: 'nothing took ownership, so nothing may be listed');
      expect(vm.error, isNotNull);
      expect(vm.isConnecting, isFalse);
    });

    test('a superseded attempt closes its channel instead of leaking it', () async {
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'yes'
        ..gate = Completer<void>();
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      final pending = vm.connect(vm.connectableServers.single);
      await pumpEventQueue();
      vm.cancelConnect();
      ssh.gate!.complete();
      await pending;

      // The shell still opens — the gate released after the cancel — so the question is purely
      // who closes it. Nothing adopted it, so this attempt has to.
      expect(ssh.opened, hasLength(1));
      expect(
        ssh.opened.single.closeCalled,
        isTrue,
        reason: 'a cancelled attempt still owns the channel it opened',
      );
      expect(vm.sessions, isEmpty);
    });

    test('a live session is not reported as a failed connection', () async {
      // `_reloadSaved` runs after the session is registered and usable. Letting it throw sent a
      // working shell's connect into the failure handlers, so the user was told the connection had
      // failed while their terminal sat in front of them.
      db = AppDatabase(NativeDatabase.memory());
      final failing = _FailsReadingAfterWriting(
        db,
        SecretStore(storage: FakeSecureStorage(<String, String>{})),
      );
      app.dispose();
      app = AppState(failing);
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'yes';
      await failing.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(vm.sessions, hasLength(1), reason: 'the shell opened and was registered');
      expect(vm.sessions.single.isOpen, isTrue, reason: 'it is a working terminal');
      expect(
        vm.error,
        contains('Connected to nas'),
        reason: 'stale bookkeeping is worth saying, but it is not a failed connection',
      );
      expect(vm.error, contains('may be out of date'));
      expect(
        vm.current,
        isNotNull,
        reason: 'the user is looking at a working terminal, not a failed-connection prompt',
      );
    });
  });

  group('tmux availability', () {
    Server persistentHost({String name = 'nas'}) =>
        server(name: name).copyWith(persistentSession: true);

    test('a host without tmux is not connected, it is asked about', () async {
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'no';
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(vm.tmuxPromptServer, isNotNull);
      expect(
        ssh.opened,
        isEmpty,
        reason: 'silently opening a non-resumable shell is the defect being fixed',
      );
    });

    test('a host with tmux connects without a prompt', () async {
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'yes';
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(vm.tmuxPromptServer, isNull);
      expect(ssh.opened, hasLength(1));
    });

    test('the probe runs once per host, not per connection', () async {
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'yes';
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      final host = vm.connectableServers.single;

      await vm.connect(host);
      final name = (await repo.getPersistentSessions()).single.tmuxName;
      ssh.execAnswers['has-session -t $name'] = tmuxSessionPresentMarker;
      await vm.connect(host);

      expect(
        ssh.commands.where((c) => c.contains('command -v tmux')).length,
        1,
        reason: 'a round trip before every connection would be felt',
      );
    });

    test('a non-persistent host is never probed', () async {
      final ssh = FakeShellTransport();
      await repo.insertServer(server(name: 'plain'));
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(ssh.commands, isEmpty);
      expect(ssh.opened, hasLength(1));
    });

    test('a probe that cannot run connects rather than blocking', () async {
      // Refusing to connect over a failed probe would be worse than the silent degradation this
      // replaces: the bootstrap command guards itself anyway.
      final ssh = FakeShellTransport(); // exec throws
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(vm.tmuxPromptServer, isNull);
      expect(ssh.opened, hasLength(1));
    });

    test('a returned transport error is not an offer to install tmux', () async {
      // The defect: `exec` reports failure by RETURNING `'SSH Error: …'`, and the probe only
      // caught thrown errors. A refused connection therefore looked like a definite "tmux is
      // missing", and the app offered to install a package over a link that did not exist.
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'SSH Error: Connection refused'
        ..failure = SshConnectException('Connection refused');
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(
        vm.tmuxPromptServer,
        isNull,
        reason: 'a host that would not answer has not told us anything about tmux',
      );
      expect(vm.error, isNotNull, reason: "the user needs the host's real failure, not a package");
      expect(vm.error, isNot(contains('tmux')));
    });

    test('an unverified probe is not remembered as verified', () async {
      // The probe is cached per host per session to avoid a round trip before every connection.
      // Caching it from an answer that never arrived means one flaky moment silently disables the
      // check for the rest of the session, on the exact host that needs it. The old code did
      // precisely that: a thrown probe returned `true`, which went straight into `_tmuxVerified`.
      final ssh = FakeShellTransport(); // no staged answer, so the probe throws
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      final host = vm.connectableServers.single;

      await vm.connect(host);
      ssh.execAnswers['command -v tmux'] = 'no';
      await vm.connect(host);

      expect(
        ssh.commands.where((c) => c.contains('command -v tmux')),
        hasLength(2),
        reason: 'the second connection must ask again, not trust a probe that never answered',
      );
      expect(vm.tmuxPromptServer, isNotNull, reason: 'now the host has actually answered "no"');
    });

    test('the probe shows a busy state while it is in flight', () async {
      // It is a round trip to the host. It used to run with `_connecting` still false, so a slow
      // probe looked exactly like a tap that had done nothing at all.
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'yes'
        ..execGate = Completer<void>();
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      final pending = vm.connect(vm.connectableServers.single);
      await pumpEventQueue();

      expect(vm.isConnecting, isTrue);
      expect(vm.connectPhase, 'Checking for tmux…');

      ssh.execGate!.complete();
      await pending;
      expect(vm.isConnecting, isFalse);
    });

    test('a second tap during the probe does not start a second connection', () async {
      // `if (_connecting) return` could not see the probe, because the probe ran before it was set.
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'yes'
        ..execGate = Completer<void>();
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      final host = vm.connectableServers.single;

      final first = vm.connect(host);
      await pumpEventQueue();
      final second = vm.connect(host);
      await pumpEventQueue();

      ssh.execGate!.complete();
      await Future.wait([first, second]);

      expect(
        ssh.commands.where((c) => c.contains('command -v tmux')),
        hasLength(1),
        reason: 'two probes means two connections were in flight',
      );
      expect(ssh.opened, hasLength(1));
    });

    test('cancelling during the probe abandons the attempt', () async {
      // Nothing owned the probe, so `cancelConnect` had nothing to cancel and its answer still
      // landed — raising a tmux prompt for a connection the user had already given up on.
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'no'
        ..execGate = Completer<void>();
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      final pending = vm.connect(vm.connectableServers.single);
      await pumpEventQueue();
      vm.cancelConnect();
      ssh.execGate!.complete();
      await pending;

      expect(vm.tmuxPromptServer, isNull, reason: 'the user cancelled before the host answered');
      expect(vm.isConnecting, isFalse);
      expect(ssh.opened, isEmpty);
    });

    test('connecting without persistence opens a plain shell', () async {
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'no';
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);
      expect(vm.tmuxPromptServer, isNotNull);

      await vm.connectWithoutPersistence();

      expect(vm.tmuxPromptServer, isNull);
      expect(ssh.opened, hasLength(1));
      expect(
        sent(ssh),
        isNot(contains('tmux')),
        reason: 'the user chose a plain shell, so no bootstrap may be written',
      );
    });

    test('a successful install connects with persistence', () async {
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'no'
        ..streamChunks = const ['reading package lists…\n', 'tmux installed\n'];
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);

      // The re-probe after installing must now answer yes.
      ssh.execAnswers['command -v tmux'] = 'yes';
      await vm.installTmuxAndConnect();

      expect(vm.tmuxPromptServer, isNull);
      expect(ssh.opened, hasLength(1));
      expect(sent(ssh), contains('tmux'));
    });

    test('a failed install keeps the prompt and says what to do', () async {
      // The installer can exit 0 against a broken mirror, so the re-probe is what decides.
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'no'
        ..streamChunks = const ['E: Unable to locate package tmux\n'];
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);

      await vm.installTmuxAndConnect();

      expect(vm.tmuxPromptServer, isNotNull, reason: 'the user still has a decision to make');
      expect(vm.tmuxInstallOutput, contains('Install did not complete'));
      expect(ssh.opened, isEmpty);
    });

    test('installer output is streamed as it arrives', () async {
      final ssh = FakeShellTransport()
        ..execAnswers['command -v tmux'] = 'no'
        ..streamChunks = const ['step one\n', 'step two\n'];
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);

      await vm.installTmuxAndConnect();

      expect(vm.tmuxInstallOutput, contains('step one'));
      expect(vm.tmuxInstallOutput, contains('step two'));
    });

    test('dismissing clears the prompt without connecting', () async {
      final ssh = FakeShellTransport()..execAnswers['command -v tmux'] = 'no';
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);
      await vm.connect(vm.connectableServers.single);

      vm.dismissTmuxPrompt();

      expect(vm.tmuxPromptServer, isNull);
      expect(ssh.opened, isEmpty);
    });
  });
}
