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
import 'support/fake_shell_transport.dart';

/// Records what the platform was asked to show, and lets a test push shade actions back.
class _FakeSessionService implements SessionService {
  final List<List<BackgroundSession>> synced = [];
  int stops = 0;
  final _actions = StreamController<SessionServiceAction>.broadcast();

  @override
  Stream<SessionServiceAction> get actions => _actions.stream;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<bool> sync(List<BackgroundSession> sessions) async {
    if (sessions.isEmpty) {
      stops++;
    } else {
      synced.add(List.of(sessions));
    }
    return true;
  }

  @override
  Future<bool> stop() async {
    stops++;
    return true;
  }

  void push(SessionServiceAction action) => _actions.add(action);

  Future<void> dispose() => _actions.close();

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

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
      expect(SessionServiceAction.parse({'action': 'disconnect'}), isNull,
          reason: 'no session id');
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
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      service = SessionService();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
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

    test('a platform without the service reports unsupported rather than throwing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      expect(await service.isSupported(), isFalse);
      expect(await service.sync(const [BackgroundSession(id: 'a', serverName: 'n')]), isFalse);
      expect(await service.stop(), isFalse);
    });
  });

  group('the shell keeps the notification honest', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;
    late FakeShellTransport transport;
    late _FakeSessionService service;
    late ShellViewModel vm;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
      transport = FakeShellTransport();
      service = _FakeSessionService();
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
      await boot();

      await vm.connect(vm.server!);

      expect(service.synced.last.single.serverName, 'nas');
    });

    test('closing the last session takes the notification down', () async {
      // A notification claiming background sessions when there are none is worse than none at all.
      await repo.insertServer(server(name: 'nas'));
      await boot();
      await vm.connect(vm.server!);

      vm.close(vm.current!);

      expect(service.stops, greaterThan(0));
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
