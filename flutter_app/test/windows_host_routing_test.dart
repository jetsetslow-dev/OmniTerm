import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/infra_view_model.dart';
import 'package:omniterm/ui/view_model/monitor_view_model.dart';

import 'monitor_view_model_test.dart' show RecordingTransport;
import 'support/fake_secure_storage.dart';

/// A Windows host gets Windows commands, or a plain "needs a Linux, macOS or BSD host", from every
/// screen that would otherwise send it a Unix shell script.
///
/// The command builders are tested on their own in `host_os_commands_test.dart`; this checks that
/// the view models actually ask the host's OS and route through them, which a builder test cannot
/// see. Mirrors `WindowsHostRoutingRobolectricTest` in the Kotlin app.
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

  Server windowsHost() => Server(
    id: 0,
    name: 'Windows fixture',
    host: 'windows.invalid',
    port: 22,
    username: 'fixture',
    serverColor: 'Default',
    authType: 'password',
    authPassword: 'pw',
    sudoPassword: 'saved-sudo',
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

  /// Answers like a Windows OpenSSH host whose shell is cmd.exe.
  RecordingTransport windowsTransport() => RecordingTransport(
    replies: {
      osProbeCommand: "'uname' is not recognized as an internal or external command,\r\n",
      servicesWindows: '$serviceTableMarker\r\nSpooler\tRunning\tAutomatic\tPrint Spooler\r\n',
    },
  );

  void expectNoUnixWords(RecordingTransport transport) {
    const unix = ['crontab', 'systemctl', 'docker', 'podman', 'kill -', 'sudo '];
    for (final command in transport.commands) {
      if (command == osProbeCommand) continue;
      if (command.startsWith('powershell ') || command.startsWith('taskkill ')) continue;
      for (final word in unix) {
        expect(command, isNot(contains(word)), reason: 'sent "$word" to a Windows host');
      }
    }
  }

  test('Monitor sends a Windows host Windows commands', () async {
    await repo.insertServer(windowsHost());
    await app.start();
    final transport = windowsTransport();
    final vm = MonitorViewModel(app, transport: transport);
    await Future<void>.delayed(Duration.zero);

    await vm.loadCron();
    expect(vm.cronReadable, isFalse, reason: 'the Cron tab must not offer Add on Windows');
    expect(vm.cronUnsupported, contains('Task Scheduler'));

    await vm.loadServices();
    expect(vm.services.single.name, 'Spooler');
    expect(vm.services.single.enabled, isTrue);

    await vm.runServiceAction(vm.services.single, 'restart');
    expect(transport.commands, contains(contains("Restart-Service -Name 'Spooler' -Force")));

    await vm.killProcess(42, signal: 9);
    expect(transport.commands, contains('taskkill /PID 42 /F 2>&1'));

    await vm.rebootMonitoredHost();
    expect(transport.commands, contains('shutdown /r /t 0 2>&1'));

    // Neither a service action nor the reboot uses sudo there, so the saved password stays home.
    expect(transport.stdins.whereType<String>(), isEmpty);
    expect(transport.commands.where((c) => c == osProbeCommand), hasLength(1));
    expectNoUnixWords(transport);
    vm.dispose();
  });

  test('Containers says a Windows host has no Unix shell to run them on', () async {
    await repo.insertServer(windowsHost());
    await app.start();
    final transport = windowsTransport();
    final vm = InfraViewModel(app, transport: transport);
    await Future<void>.delayed(Duration.zero);

    await vm.load();
    expect(vm.error, contains('Linux, macOS or BSD'));

    final deployed = await vm.deployCompose(
      path: '/srv/web/compose.yml',
      project: 'web',
      yaml: 'services: {}\n',
    );
    expect(deployed, isFalse);
    expect(vm.composeError, contains('Linux, macOS or BSD'));

    expectNoUnixWords(transport);
    vm.dispose();
  });
}
