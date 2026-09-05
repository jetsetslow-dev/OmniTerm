import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/infra_view_model.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';
import 'package:provider/provider.dart';

const _enabled = bool.fromEnvironment('OMNITERM_E2E_HOSTS');
const _host = String.fromEnvironment('OMNITERM_E2E_HOST', defaultValue: '127.0.0.1');
const _user = String.fromEnvironment('OMNITERM_TEST_USER');
const _password = String.fromEnvironment('OMNITERM_TEST_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app drives isolated Docker, Podman, SFTP, SMB, FTP and WebDAV fixtures', (
    tester,
  ) async {
    expect(_user, isNotEmpty, reason: 'scripts/test-hosts/.env was not passed to Flutter');
    expect(_password, isNotEmpty, reason: 'scripts/test-hosts/.env was not passed to Flutter');

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Read below MultiProvider; the OmniTermApp element itself is its parent and therefore cannot
    // see providers created by its own build method.
    final context = tester.element(find.byKey(const ValueKey('screen.servers')));
    final appState = context.read<AppState>();
    final infra = context.read<InfraViewModel>();
    final sftp = context.read<SftpViewModel>();
    final transport = context.read<SshTransport>();
    final trust = context.read<SshHostKeyTrust>();
    // Hold the two pollers rather than re-reading them at teardown. `context` belongs to a widget
    // that is deactivated by then, and an inherited-widget lookup on a deactivated element throws —
    // which failed the whole test after every product assertion had already passed.
    final statusProbe = context.read<HostStatusProbe>();
    final telemetryPoller = context.read<TelemetryPoller>();
    statusProbe.stop();
    telemetryPoller.stop();

    // The fixture keys are deliberately regenerated after `test-hosts.sh down`. Device tests
    // approve only those repository-controlled endpoints and record every request in the test
    // log; no personal host can be silently trusted by this harness.
    final approvalOwner = Object();
    final approvedHosts = <String>[];
    trust.registerApprovalHandler(approvalOwner, (request) {
      approvedHosts.add(request.host);
      debugPrint('HOST-E2E approve fixture key: ${request.host} ${request.keyType}');
      request.completer.complete(true);
    });
    addTearDown(() {
      trust.clearApprovalHandler(approvalOwner);
      statusProbe.stop();
      telemetryPoller.stop();
    });

    final runtimeIds = (await tester.runAsync(() async {
      final docker = await appState.repository.insertServer(
        _server(name: 'E2E Docker', port: 2205),
      );
      final podman = await appState.repository.insertServer(
        _server(name: 'E2E Podman', port: 2206),
      );
      return (docker: docker, podman: podman);
    }))!;
    await _waitFor(tester, () => appState.servers.any((row) => row.id == runtimeIds.podman));

    await _exerciseRuntime(
      tester,
      appState: appState,
      infra: infra,
      transport: transport,
      serverId: runtimeIds.docker,
      runtime: 'docker',
    );
    await _exerciseRuntime(
      tester,
      appState: appState,
      infra: infra,
      transport: transport,
      serverId: runtimeIds.podman,
      runtime: 'podman',
    );

    final shares = (await tester.runAsync(() async {
      final rows = <NetworkShare>[
        _share(name: 'E2E SFTP', protocol: 'SFTP', port: 2201, path: '/fixtures/large-stack'),
        _share(name: 'E2E SMB', protocol: 'SMB', port: 445, path: 'fixture'),
        _share(name: 'E2E FTP', protocol: 'FTP', port: 21, path: '/'),
        _share(name: 'E2E WebDAV', protocol: 'WEBDAV', port: 8082, path: '/fixture'),
      ];
      final inserted = <NetworkShare>[];
      for (final row in rows) {
        final id = await appState.repository.insertNetworkShare(row);
        inserted.add(row.copyWith(id: id));
      }
      return inserted;
    }))!;

    for (final share in shares) {
      await _exerciseShare(tester, sftp, share);
    }

    expect(
      approvedHosts.toSet(),
      containsAll(<String>{_host}),
      reason: 'at least the SSH-backed runtime/SFTP fixtures must pass host-key verification',
    );
    debugPrint('HOST-E2E complete: Docker, Podman, SFTP, SMB, FTP and WebDAV passed');
  }, skip: !_enabled);
}

Server _server({required String name, required int port}) => Server(
  id: 0,
  name: name,
  host: _host,
  port: port,
  username: _user,
  groupName: 'E2E',
  serverColor: 'Default',
  authType: 'password',
  authPassword: _password,
  sudoPassword: '',
  notes: 'Repository-controlled device fixture',
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
  lastLatency: 1,
  status: 'online',
  authStatus: 'ok',
);

NetworkShare _share({
  required String name,
  required String protocol,
  required int port,
  required String path,
}) => NetworkShare(
  id: 0,
  name: name,
  protocol: protocol,
  address: _host,
  port: port,
  sharePath: path,
  workgroup: '',
  username: _user,
  password: _password,
  anonymous: false,
  useHttps: false,
  notes: 'Repository-controlled device fixture',
  lastChecked: 0,
  lastStatus: 'online',
);

Future<void> _exerciseRuntime(
  WidgetTester tester, {
  required AppState appState,
  required InfraViewModel infra,
  required SshTransport transport,
  required int serverId,
  required String runtime,
}) async {
  debugPrint('HOST-E2E runtime start: $runtime');
  infra.selectServer(serverId);
  await tester.pump();
  final server = appState.servers.singleWhere((row) => row.id == serverId);
  final rawRuntimes = await tester.runAsync(
    () => transport.exec(
      SshCredentials(
        host: server.host,
        port: server.port,
        username: server.username,
        password: _password,
      ),
      dockerRuntimesCommand,
    ),
  );
  debugPrint('HOST-E2E runtime raw result: $runtime=${rawRuntimes?.trim()}');
  expect(rawRuntimes, contains(runtime), reason: '$runtime did not answer its app transport probe');
  await tester.runAsync(infra.load);
  expect(infra.error, isNull, reason: '$runtime runtime discovery failed: ${infra.error}');
  expect(infra.runtimes, contains(runtime));

  final project = 'omniterm-device-e2e-$runtime';
  final path = '~/omniterm-e2e/device/$runtime-compose.yml';
  final yaml = '''
services:
  smoke:
    image: alpine:3.22
    command: ["sh", "-c", "printf 'omniterm-device-e2e-ready\\n'; sleep 600"]
    labels:
      com.jetsetslow.omniterm.fixture: device-e2e
''';
  final deployed = await tester.runAsync(
    () => infra.deployCompose(path: path, project: project, yaml: yaml, runtime: runtime),
  );
  expect(deployed, isTrue, reason: '$runtime deploy failed: ${infra.composeError}');
  expect(infra.stacks.map((stack) => stack.name), contains(project));

  final stack = infra.stacks.firstWhere((candidate) => candidate.name == project);
  await tester.runAsync(() => infra.stackAction(stack, 'down'));
  await tester.runAsync(infra.load);
  expect(
    infra.stacks.where((candidate) => candidate.name == project),
    isEmpty,
    reason: '$runtime compose down did not remove the live stack',
  );
  expect(infra.downedStacks.map((candidate) => candidate.project), contains(project));
  debugPrint('HOST-E2E runtime passed: $runtime');
}

Future<void> _exerciseShare(WidgetTester tester, SftpViewModel sftp, NetworkShare share) async {
  debugPrint('HOST-E2E share start: ${share.protocol}');
  await tester.runAsync(() => sftp.openShare(share));
  expect(sftp.error, isNull, reason: '${share.protocol} listing failed: ${sftp.error}');
  final fixtureName = share.protocol == 'SFTP' ? 'compose.yml' : 'fixture.txt';
  if (share.protocol == 'SFTP') {
    expect(sftp.visibleEntries.map((entry) => entry.name), contains(fixtureName));
  } else {
    expect(sftp.visibleEntries.map((entry) => entry.name), containsAll(['fixture.txt', 'nested']));
  }

  // Drive the same read/save seam the full-screen editor uses. SFTP's committed 400-service input
  // is deliberately read-only, so it is read but never rewritten; the three writable share
  // protocols save the exact bytes back and then read them again.
  final fixture = sftp.visibleEntries.firstWhere((entry) => entry.name == fixtureName);
  final original = await tester.runAsync(() => sftp.readForEditing(fixture));
  expect(original, isNotNull, reason: '${share.protocol} editor read failed: ${sftp.error}');
  expect(
    original,
    share.protocol == 'SFTP' ? contains('services:') : contains('omniterm-share-fixture'),
  );
  if (share.protocol != 'SFTP') {
    final saved = await tester.runAsync(() => sftp.saveText(fixture, original!));
    expect(saved?.isError, isFalse, reason: '${share.protocol} editor save was not confirmed');
    final reread = await tester.runAsync(() => sftp.readForEditing(fixture));
    expect(
      reread,
      original,
      reason: '${share.protocol} editor round-trip changed the file: ${sftp.error}',
    );
  }

  if (share.protocol == 'SFTP') {
    debugPrint('HOST-E2E share passed: ${share.protocol} (read-only fixture)');
    return;
  }

  final baseName = 'omniterm-device-e2e-${share.protocol.toLowerCase()}';
  final stale = sftp.visibleEntries.where((entry) => entry.name == baseName).toList();
  if (stale.isNotEmpty) {
    await tester.runAsync(() => sftp.deleteEntries(stale));
  }

  expect(await tester.runAsync(() => sftp.createDirectory(baseName)), isNull);
  final created = sftp.visibleEntries.firstWhere((entry) => entry.name == baseName);
  expect(created.isDirectory, isTrue);

  final renamedName = '$baseName-renamed';
  final staleRenamed = sftp.visibleEntries.where((entry) => entry.name == renamedName).toList();
  if (staleRenamed.isNotEmpty) {
    await tester.runAsync(() => sftp.deleteEntries(staleRenamed));
  }
  expect(await tester.runAsync(() => sftp.rename(created, renamedName)), isNull);
  final renamed = sftp.visibleEntries.firstWhere((entry) => entry.name == renamedName);
  await tester.runAsync(() => sftp.deleteEntries([renamed]));
  expect(sftp.visibleEntries.map((entry) => entry.name), isNot(contains(renamedName)));
  expect(sftp.error, isNull, reason: '${share.protocol} mutation failed: ${sftp.error}');
  debugPrint('HOST-E2E share passed: ${share.protocol}');
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
  expect(condition(), isTrue, reason: 'timed out waiting for application state');
}
