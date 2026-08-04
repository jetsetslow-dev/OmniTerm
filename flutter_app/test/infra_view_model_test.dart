import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/infra_view_model.dart';

import 'monitor_view_model_test.dart' show RecordingTransport;
import 'support/fake_secure_storage.dart';

/// A `docker ps` row: runtime, id, name, image, status, ports, project, service, workdir, configs,
/// created.
String psRow({
  String runtime = 'docker',
  required String id,
  required String name,
  String image = 'nginx:latest',
  String status = 'Up 2 hours',
  String ports = '0.0.0.0:8080->80/tcp',
  String project = 'web',
  String service = 'front',
  String workdir = '/srv/web',
  String configs = 'docker-compose.yml',
  String created = '2026-08-01 10:00:00 +0000 UTC',
}) =>
    [runtime, id, name, image, status, ports, project, service, workdir, configs, created]
        .join('\t');

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
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

  Future<InfraViewModel> boot({RecordingTransport? transport}) async {
    await app.start();
    await Future<void>.delayed(Duration.zero);
    return InfraViewModel(app, transport: transport);
  }

  group('loading', () {
    test('all six probes are issued, and concurrently', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport();
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      // Serialising six independent probes would multiply latency by six on the screen a user
      // opens to check something quickly.
      expect(transport.commands, hasLength(6));
      vm.dispose();
    });

    test('containers are parsed and rolled up into stacks', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': [
            psRow(id: 'a1', name: 'web_front_1', service: 'front'),
            psRow(id: 'a2', name: 'web_db_1', service: 'db', ports: '—'),
          ].join('\n'),
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(vm.containers, hasLength(2));
      expect(vm.stacks, hasLength(1));
      final stack = vm.stacks.single;
      expect(stack.name, 'web');
      expect(stack.total, 2);
      expect(stack.services.map((s) => s.name), ['db', 'front']);
      expect(stack.exposedPorts, 1, reason: 'the db container publishes nothing');
      vm.dispose();
    });

    test('restart counts are attached, keyed by runtime and id', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
          'inspect': 'docker\ta1\t7',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(vm.containers.single.restartCount, 7);
      expect(vm.stacks.single.restartCount, 7,
          reason: 'a stack that is "running" but restarted repeatedly is not healthy');
      vm.dispose();
    });

    test('an image used by a container is marked in use', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1', image: 'nginx:latest'),
          'images --no-trunc': 'docker\tsha256:abc\tnginx\tlatest\t50MB\t2 days ago\n'
              'docker\tsha256:def\tredis\t7\t30MB\t3 days ago',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(vm.images.firstWhere((i) => i.repository == 'nginx').inUse, isTrue);
      expect(vm.images.firstWhere((i) => i.repository == 'redis').inUse, isFalse);
      vm.dispose();
    });

    test('a Podman image is not marked in use by a Docker container', () async {
      // A host running both pulls the same repo:tag into each; crossing them would let the UI
      // offer to delete an image that is actually running.
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1', image: 'nginx:latest'),
          'images --no-trunc': 'podman\tsha256:abc\tnginx\tlatest\t50MB\t2 days ago',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(vm.images.single.inUse, isFalse);
      vm.dispose();
    });
  });

  group('failures', () {
    test('a transport failure clears the lists rather than showing stale rows', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();
      expect(vm.containers, isNotEmpty);

      transport.failure = Exception('connection reset');
      await vm.load();

      expect(vm.error, contains('connection reset'));
      expect(vm.containers, isEmpty, reason: 'stale rows presented as current state mislead');
      expect(vm.downedStacks, isEmpty,
          reason: 'a transport failure is no evidence that a stack is down');
      vm.dispose();
    });

    test('a credential failure surfaces as an error', () async {
      await repo.insertServer(
        server(name: 'nas').copyWith(authType: 'key', authKeyAlias: const Value('gone')),
      );
      final vm = await boot(transport: RecordingTransport());
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(vm.error, contains('gone'));
      vm.dispose();
    });

    test('without a transport it says so rather than showing an empty host', () async {
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot();
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(vm.canInspect, isFalse);
      expect(vm.error, isNotNull);
      vm.dispose();
    });
  });

  group('the downed-stack registry', () {
    test('a live stack is remembered', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      final known = await repo.getStacksForServer(id);
      expect(known.single.project, 'web');
      expect(known.single.workingDir, '/srv/web');
      expect(vm.downedStacks, isEmpty, reason: 'it is running right now');
      vm.dispose();
    });

    test('a stack that disappears is reported as down, not forgotten', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      // `compose down` removes the containers but leaves the file on disk.
      transport.replies = {'ps -a --no-trunc': ''};
      await vm.load();

      expect(vm.stacks, isEmpty);
      expect(vm.downedStacks.single.project, 'web',
          reason: 'it can be brought back up, so it must stay visible');
      vm.dispose();
    });

    test('a stack with no working directory is not remembered', () async {
      // No working directory means no compose action can ever run for it, including a later "up",
      // so there is nothing actionable to record.
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1', workdir: '', configs: ''),
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(await repo.getStacksForServer(id), isEmpty);
      vm.dispose();
    });

    test('standalone containers are never recorded as a stack', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc':
              psRow(id: 'a1', name: 'loose', project: '', service: '', workdir: ''),
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      expect(await repo.getStacksForServer(id), isEmpty);
      vm.dispose();
    });

    test('forgetting a downed stack removes it locally only', () async {
      final id = await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();
      transport.replies = {'ps -a --no-trunc': ''};
      await vm.load();

      final commandsBefore = transport.commands.length;
      await vm.forgetDownedStack(vm.downedStacks.single);

      expect(vm.downedStacks, isEmpty);
      expect(await repo.getStacksForServer(id), isEmpty);
      expect(transport.commands.length, commandsBefore,
          reason: 'forgetting must not touch the host');
      vm.dispose();
    });

    test('bringing up a stack whose file has vanished explains why', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();
      transport.replies = {'ps -a --no-trunc': ''};
      await vm.load();

      // The probe answers MISSING; compose's own error here is confusing.
      transport.replies = {
        'ps -a --no-trunc': '',
        'OMNITERM_COMPOSE_OK': 'OMNITERM_COMPOSE_MISSING',
      };
      await vm.bringUpDownedStack(vm.downedStacks.single);

      expect(vm.actionOutput, contains('no longer at /srv/web'));
      expect(transport.commands.any((c) => c.contains('up -d')), isFalse,
          reason: 'nothing should be launched when the file is gone');
      vm.dispose();
    });

    test('bringing up a stack whose file is present runs compose up', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();
      transport.replies = {'ps -a --no-trunc': ''};
      await vm.load();

      transport.replies = {
        'ps -a --no-trunc': '',
        'OMNITERM_COMPOSE_OK': 'OMNITERM_COMPOSE_OK',
      };
      await vm.bringUpDownedStack(vm.downedStacks.single);

      final up = transport.commands.firstWhere((c) => c.contains(r'$OT_COMPOSE'));
      expect(up, contains("cd '/srv/web'"));
      expect(up, contains("-p 'web'"));
      expect(up, contains('up -d'));
      vm.dispose();
    });
  });

  group('actions', () {
    test('a container action targets that container on its own runtime', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(runtime: 'podman', id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      await vm.containerAction(vm.containers.single, 'restart');
      expect(transport.commands.any((c) => c == "podman restart 'a1' 2>&1"), isTrue);
      vm.dispose();
    });

    test('an action refetches rather than guessing the new state', () async {
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();
      final before = transport.commands.length;

      await vm.containerAction(vm.containers.single, 'stop');

      expect(transport.commands.length, before + 7,
          reason: 'one action plus a full six-probe refresh');
      vm.dispose();
    });

    test('a stack action cds into the working directory', () async {
      // Compose resolves relative bind mounts and .env against the working directory, so running
      // from elsewhere can silently bring up a different stack from the same file.
      await repo.insertServer(server(name: 'nas'));
      final transport = RecordingTransport(replies: {
        'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
      });
      final vm = await boot(transport: transport);
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      await vm.stackAction(vm.stacks.single, 'restart');
      final cmd = transport.commands.firstWhere((c) => c.contains(r'$OT_COMPOSE'));
      expect(cmd, contains("cd '/srv/web'"));
      expect(cmd, contains("-f 'docker-compose.yml'"));
      vm.dispose();
    });

    test('action output is surfaced verbatim', () async {
      // Compose failures are diagnosed from their exact wording.
      await repo.insertServer(server(name: 'nas'));
      final vm = await boot(
        transport: RecordingTransport(replies: {
          'ps -a --no-trunc': psRow(id: 'a1', name: 'web_front_1'),
          'restart': 'Error response from daemon: no such container',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      await vm.load();

      await vm.containerAction(vm.containers.single, 'restart');
      expect(vm.actionOutput, 'Error response from daemon: no such container');
      vm.dispose();
    });
  });

  test('a selected host that goes offline is not inspected', () async {
    final aId = await repo.insertServer(server(name: 'a'));
    final bId = await repo.insertServer(server(name: 'b'));
    final vm = await boot(transport: RecordingTransport());
    app.selectedServerId = aId;
    await Future<void>.delayed(Duration.zero);
    expect(vm.inspectedServer?.id, aId);

    await repo.updateServer((await repo.getServerById(aId))!.copyWith(status: 'offline'));
    await Future<void>.delayed(Duration.zero);

    expect(vm.inspectedServer?.id, bId);
    vm.dispose();
  });
}
