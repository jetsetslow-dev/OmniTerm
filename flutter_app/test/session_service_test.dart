import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/platform/session_service.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';

import 'support/fake_secure_storage.dart';
import 'support/fake_session_service.dart';
import 'support/fake_shell_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shade actions', () {
    test('a disconnect names its session', () {
      expect(
        SessionServiceAction.parse({'action': 'disconnect', 'session': 'abc'}),
        const DisconnectSession('abc'),
      );
    });

    test('disconnect-all needs no session', () {
      expect(
        SessionServiceAction.parse({'action': 'disconnectAll'}),
        const DisconnectAllSessions(),
      );
    });

    test('resume names its session', () {
      expect(
        SessionServiceAction.parse({'action': 'resume', 'session': 'abc'}),
        const ResumeSession('abc'),
      );
    });

    test('anything malformed is ignored rather than guessed at', () {
      // A shade message the app cannot read must not be turned into a disconnect by accident.
      expect(SessionServiceAction.parse(null), isNull);
      expect(SessionServiceAction.parse('disconnect'), isNull);
      expect(SessionServiceAction.parse({'action': 'disconnect'}), isNull, reason: 'no session id');
      expect(SessionServiceAction.parse({'action': 'explode', 'session': 'a'}), isNull);
    });
  });

  group('the channel', () {
    late List<MethodCall> calls;
    late MethodChannel channel;
    late SessionService service;

    setUp(() {
      calls = [];
      channel = const MethodChannel(SessionService.methodChannelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          calls.add(call);
          return true;
        },
      );
      service = SessionService();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });

    test('syncing sends every session', () async {
      await service.sync(const [
        BackgroundSession(id: 'a', serverName: 'nas'),
        BackgroundSession(id: 'b', serverName: 'pi'),
      ]);

      expect(calls.single.method, 'sync');
      final sessions = (calls.single.arguments as Map)['sessions'] as List;
      expect(sessions, hasLength(2));
      expect((sessions.first as Map)['serverName'], 'nas');
    });

    test('syncing an empty list stops the service', () async {
      // A foreground notification with nothing behind it is a lie.
      await service.sync(const []);
      expect(calls.single.method, 'stop');
    });

    test('a platform without the service reports unsupported, not failure', () async {
      // The distinction this test exists for: iOS has no foreground service and never will, so
      // reporting that as a failure would put a permanent, unactionable warning on the screen.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );

      expect(await service.isSupported(), isFalse);
      final synced = await service.sync(const [BackgroundSession(id: 'a', serverName: 'n')]);
      expect(synced.outcome, SessionServiceOutcome.unsupported);
      expect(synced.failed, isFalse);
      expect((await service.stop()).outcome, SessionServiceOutcome.unsupported);
    });

    test('a platform that refuses reports the refusal, with its reason', () async {
      // Android 12+ throws ForegroundServiceStartNotAllowedException for a background start. That
      // is a device that DOES support this saying no, and the user can act on it.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(
          code: 'session_service_failed',
          message: 'ForegroundServiceStartNotAllowedException',
        ),
      );

      final result = await service.sync(const [BackgroundSession(id: 'a', serverName: 'n')]);
      expect(result.outcome, SessionServiceOutcome.failed);
      expect(result.detail, contains('ForegroundServiceStartNotAllowed'));
    });

    test('a platform that answers false is a refusal, not an absence', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => false,
      );

      final result = await service.sync(const [BackgroundSession(id: 'a', serverName: 'n')]);
      expect(result.outcome, SessionServiceOutcome.failed);
      expect(result.detail, isNotNull);
    });
  });

  group('the shell keeps the notification honest', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late FakeShellTransport transport;
    late FakeSessionService service;
    late ShellViewModel vm;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
      transport = FakeShellTransport();
      service = FakeSessionService();
    });

    tearDown(() async {
      vm.dispose();
      app.dispose();
      await service.dispose();
      await transport.dispose();
      await db.close();
    });

    Server server({required String name}) => Server(
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
      status: 'online',
      authStatus: 'ok',
    );

    Future<ShellViewModel> boot() async {
      await app.start();
      await Future<void>.delayed(Duration.zero);
      return vm = ShellViewModel(app, transport: transport, sessionService: service);
    }

    test('opening a session tells the platform about it', () async {
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await boot();

      await vm.connect(vm.server!);

      expect(service.synced.last.single.serverName, 'nas');
    });

    test('a refused keep-alive is said out loud, not swallowed', () async {
      // The defect: the result was used only to clear a cache so the next change would retry, and
      // was otherwise discarded. The user went on believing their shells were protected in the
      // background when Android had refused to protect them.
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await boot();
      service.result = const SessionServiceResult.failed('ForegroundServiceStartNotAllowed');

      await vm.connect(vm.server!);
      await pumpEventQueue();

      expect(vm.backgroundServiceWarning, isNotNull);
      expect(vm.backgroundServiceWarning, contains('may not survive'));
      expect(
        vm.backgroundServiceWarning,
        contains('ForegroundServiceStartNotAllowed'),
        reason: "the platform's own reason is the only actionable part",
      );
    });

    test('a platform without the service says nothing at all', () async {
      // iOS has no foreground service and never will. A permanent warning the user cannot act on
      // is worse than silence, which is why `bool` was not good enough here.
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await boot();
      service.result = const SessionServiceResult.unsupported();

      await vm.connect(vm.server!);
      await pumpEventQueue();

      expect(vm.backgroundServiceWarning, isNull);
    });

    test('an unchanged failure is not re-announced on every output frame', () async {
      // _syncBackgroundSessions runs off session notifications, which arrive constantly while a
      // shell is producing output. Re-announcing would bury the terminal under its own warning.
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await boot();
      service.result = const SessionServiceResult.failed('refused');

      await vm.connect(vm.server!);
      await pumpEventQueue();
      var notifications = 0;
      vm.addListener(() => notifications++);

      vm.setTerminalVisible(false);
      vm.setTerminalVisible(true);
      await pumpEventQueue();

      expect(vm.backgroundServiceWarning, isNotNull);
      expect(
        notifications,
        lessThan(3),
        reason: 'the warning text did not change, so it must not notify again',
      );
    });

    test('the warning can be dismissed and comes back only on a new failure', () async {
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await boot();
      service.result = const SessionServiceResult.failed('refused');
      await vm.connect(vm.server!);
      await pumpEventQueue();
      expect(vm.backgroundServiceWarning, isNotNull);

      vm.dismissBackgroundServiceWarning();
      expect(vm.backgroundServiceWarning, isNull);

      service.result = const SessionServiceResult.failed('refused again, differently');
      vm.setTerminalVisible(false);
      await pumpEventQueue();

      expect(vm.backgroundServiceWarning, contains('refused again'));
    });

    test('closing the last session takes the notification down', () async {
      // A notification claiming background sessions when there are none is worse than none at all.
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);

      vm.close(vm.current!);

      expect(service.stops, greaterThan(0));
    });

    test('output frames and visibility changes do not restart unchanged protection', () async {
      await repo.insertServer(server(name: 'nas'));
      await repo.insertSetting('background_keep_alive', 'true');
      await boot();
      await vm.connect(vm.server!);
      final starts = service.synced.length;
      final stops = service.stops;
      for (var i = 0; i < 30; i++) {
        vm.current!.publishNow();
        vm.setTerminalVisible(false);
        vm.setTerminalVisible(true);
      }
      expect(service.synced, hasLength(starts));
      expect(service.stops, stops);
    });

    test('a session that dies on its own drops out of the notification', () async {
      // The shade must not keep offering to resume a session the network already took away.
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);
      service.synced.clear();

      await transport.opened.last.dropConnection();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(service.stops, greaterThan(0), reason: 'no open sessions left to advertise');
    });

    test('Disconnect from the shade closes that session', () async {
      // The service cannot close a channel living in Dart, so the button travels back here.
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);
      final id = vm.current!.id;

      service.push(DisconnectSession(id));
      await Future<void>.delayed(Duration.zero);

      expect(vm.sessions, isEmpty);
    });

    test('Disconnect all closes every session', () async {
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);
      await vm.connect(vm.server!);
      expect(vm.sessions, hasLength(2));

      service.push(const DisconnectAllSessions());
      await Future<void>.delayed(Duration.zero);

      expect(vm.sessions, isEmpty);
    });

    test('notification resume supersedes a pending leave without closing the live tab', () async {
      await repo.insertServer(server(name: 'nas').copyWith(persistentSession: true));
      await boot();
      await vm.connect(vm.server!);
      final session = vm.current!;
      final locked = Completer<void>();
      final release = Completer<void>();
      final holding = db.transaction(() async {
        await db.customSelect('SELECT 1').get();
        locked.complete();
        await release.future;
      });
      await locked.future;
      final leaving = vm.leaveResumable(session);
      try {
        expect(vm.isLeavingSessions, isTrue);
        service.push(ResumeSession(session.id));
        await Future<void>.delayed(Duration.zero);
      } finally {
        release.complete();
        await holding;
      }
      expect(await leaving.timeout(const Duration(seconds: 5)), isFalse);
      expect(vm.current, same(session));
      expect(session.isOpen, isTrue);
      expect(vm.isLeavingSessions, isFalse);
      expect(vm.error, isNull);
    });

    test('an action for an unknown session is ignored', () async {
      // The shade can outlive the session it names.
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);

      service.push(const DisconnectSession('gone'));
      await Future<void>.delayed(Duration.zero);

      expect(vm.sessions, hasLength(1));
    });

    test('disposing takes the notification down', () async {
      // The service outlives the view model; a foreground notification left standing over nothing
      // is the kind of thing users uninstall an app for.
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);
      final before = service.stops;

      vm.dispose();

      expect(service.stops, greaterThan(before));
      vm = ShellViewModel(app);
    });
  });
}
