import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/ssh/dartssh_transport.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';
import 'package:omniterm/domain/terminal_key_encoder.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/fleet_view_model.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/infra_view_model.dart';
import 'package:omniterm/ui/view_model/sftp_view_model.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';
import 'package:omniterm/ui/widgets/terminal_surface.dart';
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
    final terminals = context.read<ShellViewModel>();
    final fleet = context.read<FleetViewModel>();
    final navigation = context.read<NavigationController>();
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

    await _exerciseTerminals(
      tester,
      terminals,
      navigation,
      transport,
      appState.servers.singleWhere((row) => row.id == runtimeIds.docker),
    );

    await tester.runAsync(() => _exerciseCommandCancellation(trust));

    final draft = fleet.commandText;
    fleet.commandText = 'unsent fixture broadcast';
    fleet.activeTab = FleetTab.dashboard;
    navigation.navigateTo(Screen.fleet);
    await tester.pumpAndSettle();
    for (final action in ['uptime', 'df', 'ps']) {
      final button = find.byKey(ValueKey('fleet.host.${runtimeIds.docker}.$action'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(find.byKey(const ValueKey('command.stream.dialog')), findsOneWidget);
      await _waitForPopup(tester, find.byKey(const ValueKey('command.stream.dialog')));
      await _waitFor(tester, () => find.text('Command finished.').evaluate().isNotEmpty);
      expect(find.textContaining('SSH Error:'), findsNothing);
      expect(find.textContaining('Command failed:'), findsNothing);
      expect(fleet.activeTab, FleetTab.dashboard);
      expect(fleet.commandText, 'unsent fixture broadcast');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    }
    fleet.commandText = draft;

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

Future<void> _exerciseCommandCancellation(SshHostKeyTrust trust) async {
  var authentications = 0;
  final transport = DartSshTransport(
    trust,
    printDebug: (line) {
      if (line == 'SSHClient._handleUserauthSuccess') authentications++;
    },
  );
  const credentials = SshCredentials(host: _host, port: 2205, username: _user, password: _password);
  final tokens = List.generate(4, (_) => SshCancellationToken());
  final ready = List.generate(4, (_) => Completer<void>());
  final chunks = List.generate(4, (_) => <String>[]);
  final running = <Future<String>>[];
  final queuedToken = SshCancellationToken();
  try {
    for (var i = 0; i < 4; i++) {
      running.add(
        transport.execStream(
          credentials,
          // Block on channel stdin, not a timing-dependent sleep or a persistent remote process.
          'printf "cancel-ready-$i\\n"; read -r fixture_reply; printf "cancel-finished-$i\\n"',
          cancellation: tokens[i],
          onChunk: (chunk) async {
            chunks[i].add(chunk);
            if (chunks[i].join().contains('cancel-ready-$i') && !ready[i].isCompleted) {
              ready[i].complete();
            }
          },
        ),
      );
    }
    await Future.wait(ready.map((signal) => signal.future)).timeout(const Duration(seconds: 20));
    var queuedOutput = false;
    final queued = transport.execStream(
      credentials,
      'printf must-not-run',
      cancellation: queuedToken,
      onChunk: (_) async => queuedOutput = true,
    );
    queuedToken.cancel();
    expect(await queued.timeout(const Duration(seconds: 2)), 'Cancelled');
    expect(queuedOutput, isFalse);
    for (var i = 0; i < 4; i++) {
      tokens[i].cancel();
      expect(await running[i].timeout(const Duration(seconds: 2)), 'Cancelled');
      for (var sibling = i + 1; sibling < 4; sibling++) {
        expect(chunks[sibling].join(), isNot(contains('cancel-finished')));
      }
    }
    expect(
      await transport.exec(credentials, 'printf cancellation-followup-ok'),
      'cancellation-followup-ok',
    );
    expect(queuedOutput, isFalse);
    expect(chunks.every((output) => !output.join().contains('cancel-finished')), isTrue);
    expect(
      authentications,
      1,
      reason: 'Stop must preserve the healthy pooled connection for reuse',
    );
    debugPrint(
      'HOST-E2E cancellation: queued work stopped, active channels closed, follow-up passed',
    );
  } finally {
    queuedToken.cancel();
    for (final token in tokens) {
      token.cancel();
    }
    try {
      await Future.wait(running).timeout(const Duration(seconds: 5));
    } finally {
      transport.shutdown();
    }
    await queuedToken.close();
    for (final token in tokens) {
      await token.close();
    }
  }
}

Future<void> _exerciseTerminals(
  WidgetTester tester,
  ShellViewModel terminals,
  NavigationController navigation,
  SshTransport transport,
  Server server,
) async {
  navigation.navigateTo(Screen.shell);
  await tester.pump();
  for (final (persistent, control) in [(false, false), (true, false), (true, true)]) {
    final label = control ? 'control' : (persistent ? 'tmux' : 'plain');
    debugPrint('HOST-E2E terminal start: $label');
    await tester.runAsync(
      () => terminals.connect(server.copyWith(persistentSession: persistent), controlMode: control),
    );
    expect(terminals.error, isNull);
    final session = terminals.current!;
    try {
      await _waitFor(tester, () => session.isOpen && (!control || session.controlPaneId != null));
      await tester.pump();
      expect(find.byType(TerminalSurface), findsWidgets);
      String transcript() => session.emulator.snapshot().rows.map((row) => row.text).join('\n');
      expect(terminals.paste("printf 'term-%s-ok\\n' '$label'"), isTrue);
      expect(terminals.sendKey(TermKey.enter), isTrue);
      await _waitFor(tester, () => transcript().contains('term-$label-ok'));
      if (!persistent) {
        expect(terminals.paste(r'for i in $(seq 1 200); do echo copy-row-$i; done'), isTrue);
        // Bracketed paste deliberately does not execute pasted newlines at a live shell prompt.
        expect(terminals.sendKey(TermKey.enter), isTrue);
        await _waitFor(
          tester,
          () => transcript().contains('copy-row-200'),
          diagnostic: () {
            final text = transcript();
            return 'plain fixture output missing: open=${session.isOpen}, '
                'grid=${session.cols}x${session.rows}, bracketed=${session.emulator.bracketedPasteMode}; '
                'tail=${text.substring(text.length > 1600 ? text.length - 1600 : 0)}';
          },
        );
        await tester.longPress(find.byType(TerminalSurface).first);
        await _waitForPopup(tester, find.byKey(const ValueKey('transcript.toggleRange')));
        await tester.tap(find.byKey(const ValueKey('transcript.toggleRange')));
        await _waitFor(tester, () => find.text('↓ More below').evaluate().isNotEmpty);
        final copiedText = tester
            .widget<SelectableText>(find.byKey(const ValueKey('transcript.text')))
            .data!;
        expect(copiedText, contains('copy-row-1\n'));
        expect(copiedText, contains('copy-row-200'));
        await tester.drag(
          find
              .ancestor(
                of: find.byKey(const ValueKey('transcript.text')),
                matching: find.byType(SingleChildScrollView),
              )
              .first,
          const Offset(0, -180),
        );
        await _waitFor(tester, () => find.text('↑ More above').evaluate().isNotEmpty);
        await tester.tap(find.byKey(const ValueKey('transcript.close')));
        await tester.pump();
      }
      for (var cycle = 0; cycle < 3; cycle++) {
        terminals.setTerminalVisible(false);
        await tester.pump(const Duration(milliseconds: 100));
        terminals.setTerminalVisible(true);
        expect(terminals.current, same(session));
        expect(session.isOpen, isTrue);
        expect(session.reconnecting, isFalse);
      }
      if (control) {
        final credentials = SshCredentials(
          host: server.host,
          port: server.port,
          username: server.username,
          password: _password,
        );
        final originalPane = session.controlPaneId!;
        // Populate an inactive window, then select it only after the output is already quiet.
        // A control client gets no automatic terminal repaint on selection.
        final quietPane = (await tester.runAsync(
          () => transport.exec(
            credentials,
            'tmux new-window -d -P -F \'#{pane_id}\' -t ${shellQuote(session.tmuxName!)} '
            '${shellQuote("printf 'quiet-window-ready\\n'; exec sleep 120")}',
          ),
        ))!.trim();
        expect(quietPane, matches(RegExp(r'^%\d+$')));
        final populated = await tester.runAsync(() async {
          for (var attempt = 0; attempt < 50; attempt++) {
            final screen = await transport.exec(
              credentials,
              'tmux capture-pane -p -t ${shellQuote(quietPane)}',
            );
            if (screen.contains('quiet-window-ready')) return true;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return false;
        });
        expect(populated, isTrue);
        await tester.runAsync(
          () => transport.exec(credentials, 'tmux select-window -t ${shellQuote(quietPane)}'),
        );
        await _waitFor(tester, () => session.controlPaneId == quietPane);
        await _waitFor(tester, () => transcript().contains('quiet-window-ready'));
        expect(transcript(), isNot(contains('term-$label-ok')));
        await tester.runAsync(
          () => transport.exec(credentials, 'tmux select-window -t ${shellQuote(originalPane)}'),
        );
        await _waitFor(tester, () => session.controlPaneId == originalPane);
        await _waitFor(tester, () => transcript().contains('term-$label-ok'));
        var sawReconnect = false;
        void observeReconnect() => sawReconnect |= session.reconnecting;
        session.addListener(observeReconnect);
        addTearDown(() => session.removeListener(observeReconnect));
        // End only this test's control client, leaving its uniquely named tmux session alive.
        await tester.runAsync(
          () => transport.exec(
            SshCredentials(
              host: server.host,
              port: server.port,
              username: server.username,
              password: _password,
            ),
            'tmux detach-client -s ${shellQuote(session.tmuxName!)}',
          ),
        );
        await _waitFor(tester, () => sawReconnect);
        await _waitFor(tester, () => session.isOpen && session.controlPaneId != null);
        expect(terminals.current, same(session));
        expect(transcript(), contains('term-$label-ok'));
        expect(terminals.paste("printf 'after-%s-ok\\n' '$label'"), isTrue);
        expect(terminals.sendKey(TermKey.enter), isTrue);
        await _waitFor(tester, () => transcript().contains('after-$label-ok'));
      }
    } finally {
      if (persistent) {
        await tester.runAsync(() => terminals.terminate(session));
      } else {
        terminals.close(session);
      }
      await tester.pump();
    }
    debugPrint('HOST-E2E terminal passed: $label');
  }
  navigation.navigateTo(Screen.servers);
  await tester.pump();
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
  String Function()? diagnostic,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
  expect(
    condition(),
    isTrue,
    reason: condition() ? null : diagnostic?.call() ?? 'timed out waiting for application state',
  );
}

Future<void> _waitForPopup(WidgetTester tester, Finder finder) => _waitFor(tester, () {
  final element = finder.evaluate().firstOrNull;
  if (element == null) return false;
  // A modal's widgets exist while the entrance animation still puts its controls off screen.
  // Wait for the route transition, not just presence, before injecting taps.
  final animation = ModalRoute.of(element)?.animation;
  return animation == null || animation.status == AnimationStatus.completed;
});
