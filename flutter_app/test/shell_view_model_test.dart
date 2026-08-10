import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/domain/terminal_key_encoder.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';

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
    repo = AppRepository(
      db,
      SecretStore(storage: FakeSecureStorage(<String, String>{})),
    );
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

  String sent(FakeShellTransport t) => t.opened.last.writes
      .map((b) => utf8.decode(b, allowMalformed: true))
      .join();

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

    test(
      'with a session open, the header names that session\'s host',
      () async {
        await repo.insertServer(server(name: 'a'));
        await repo.insertServer(server(name: 'b'));
        await start();

        await vm.connect(
          vm.connectableServers.firstWhere((s) => s.name == 'b'),
        );

        expect(
          vm.server!.name,
          'b',
          reason: 'the header must name the terminal on screen',
        );
      },
    );
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
      transport = FakeShellTransport(phases: ['Authenticating…'])
        ..gate = Completer<void>();
      await start();

      final pending = vm.connect(vm.server!);
      await Future<void>.delayed(Duration.zero);

      expect(vm.isConnecting, isTrue);
      expect(vm.connectPhase, 'Authenticating…');

      transport.gate!.complete();
      await pending;
      expect(vm.connectPhase, isNull);
    });

    test(
      'a credential problem is reported in the user\'s terms, not as a stack trace',
      () async {
        await repo.insertServer(
          server(name: 'nas', authType: 'key', authKeyAlias: 'gone'),
        );
        await start();

        await vm.connect(vm.server!);

        expect(vm.sessions, isEmpty);
        expect(vm.error, contains('gone'));
        expect(vm.error, isNot(contains('Exception')));
      },
    );

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

      expect(
        session.emulator.trimmedRowCount,
        greaterThan(0),
        reason: 'a limit is in force',
      );
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
        app.preferences.copyWith(
          terminalScrollbackLimit: PreferenceLimits.terminalScrollback.min,
        ),
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

      app.applyPreferences(
        app.preferences.copyWith(terminalScrollbackLimit: 20000),
      );
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
      expect(
        vm.ctrl,
        isTrue,
        reason: 'the modifier still belongs to the next keystroke',
      );
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
    test(
      'closing one selects another rather than leaving nothing focused',
      () async {
        await repo.insertServer(server(name: 'nas'));
        await start();
        await vm.connect(vm.server!);
        final first = vm.sessions.first;
        await vm.connect(vm.server!);

        vm.close(vm.current!);

        expect(vm.sessions, hasLength(1));
        expect(vm.current!.id, first.id);
      },
    );

    test(
      'a session that ended keeps its place until it is dismissed',
      () async {
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
      },
    );

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

      expect(
        sent(transport),
        isEmpty,
        reason: 'nothing should be typed into a plain shell',
      );
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

      await vm.connect(host);
      final second = sent(transport);

      expect(second, contains('has-session -t $name'));
      expect(second, contains('attach-session -t $name'));
      // Recreated under the *same* name if the server lost it, rather than the reconnect silently
      // dropping the user into an ordinary, non-persistent shell.
      expect(second, contains('new-session -d -s $name'));
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
      expect(
        after.tmuxName,
        before.tmuxName,
        reason: 'the same row, not a second one',
      );
      expect(after.serverId, before.serverId);
      expect(
        after.createdAt,
        before.createdAt,
        reason: 'when it started is not when it was left',
      );
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

      await vm.resume(
        vm.resumableSessions.firstWhere(
          (r) => r.tmuxName == 'omniterm-1-older',
        ),
      );

      expect(sent(transport), contains('attach-session -t omniterm-1-older'));
      expect(sent(transport), isNot(contains('omniterm-1-newer')));
    });

    test(
      'forgetting removes the pointer and says the server keeps running it',
      () async {
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
      },
    );

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

    test('the tmux name never carries anything a shell would act on', () async {
      // The name is interpolated into a command the *remote* runs. It is derived from the host id
      // and a timestamp, but the sanitiser is what makes that safe rather than the derivation.
      final transport = FakeShellTransport();
      final vm = await start(ssh: transport);
      await repo.insertServer(
        server(name: r'evil; rm -rf ~ $(id)', persistent: true),
      );
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
        reason:
            'silently opening a non-resumable shell is the defect being fixed',
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

    test('a probe that cannot run assumes tmux is there', () async {
      // Refusing to connect over a failed probe would be worse than the silent degradation this
      // replaces: the bootstrap command guards itself anyway.
      final ssh = FakeShellTransport(); // exec throws
      await repo.insertServer(persistentHost());
      final vm = await start(ssh: ssh);

      await vm.connect(vm.connectableServers.single);

      expect(vm.tmuxPromptServer, isNull);
      expect(ssh.opened, hasLength(1));
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

      expect(
        vm.tmuxPromptServer,
        isNotNull,
        reason: 'the user still has a decision to make',
      );
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
