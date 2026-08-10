import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/remote_parsers.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/server_credentials.dart';
import '../../domain/stack_summary.dart';
// Widget-free data and logic that happens to live under ui/screens; importing it here is a
// directory-layout wrinkle, not a layering inversion.
import '../screens/infra/compose_builder_logic.dart';
import 'app_state.dart';

/// The Infra screen's five sub-tabs, in the Kotlin's order (`ui/InfraScreen.kt` line 71).
enum InfraTab { stacks, builder, images, volumes, networks }

/// The Infra (containers) screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
class InfraViewModel extends ChangeNotifier {
  InfraViewModel(this._app, {this.transport}) {
    _app.addListener(_onAppChanged);
  }

  final AppState _app;

  /// Null in tests and in any build without a transport wired; the screen then says container
  /// inspection is unavailable rather than showing empty lists, which would read as "this host runs
  /// no containers".
  final SshTransport? transport;

  bool get canInspect => transport != null;

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ── which host is inspected ─────────────────────────────────────────────────

  /// The host whose containers are shown: the explicitly selected one **if it is still online**,
  /// else the first online host. Same rule as Monitor — see MIGRATION.md §15.4 for why the Kotlin's
  /// unconditional version left the screen showing a host its own picker no longer listed.
  Server? get inspectedServer {
    final online = _app.servers.where((s) => s.status == 'online');
    final selectedId = _app.selectedServerId;
    for (final server in online) {
      if (server.id == selectedId) return server;
    }
    return online.firstOrNull;
  }

  List<Server> get onlineServers => _app.servers.where((s) => s.status == 'online').toList();

  bool get hasNoOnlineHosts => inspectedServer == null;

  void selectServer(int? id) => _app.selectedServerId = id;

  int? _lastServerId;

  void _onAppChanged() {
    final current = inspectedServer?.id;
    if (current != _lastServerId) {
      _lastServerId = current;
      // Another host's containers are not this host's. Showing them while the new fetch is in
      // flight would attribute one machine's stacks to another.
      _containers = const [];
      _images = const [];
      _volumes = const [];
      _networks = const [];
      _downedStacks = const [];
      _runtimes = const {};
      _error = null;
      _actionOutput = null;
      if (current != null) unawaited(load());
    }
    _safeNotify();
  }

  // ── tabs ────────────────────────────────────────────────────────────────────

  InfraTab _activeTab = InfraTab.stacks;

  InfraTab get activeTab => _activeTab;

  set activeTab(InfraTab value) {
    if (_activeTab == value) return;
    _activeTab = value;
    notifyListeners();
  }

  /// The Builder tab's in-progress edit, parked here while the tab is not built.
  ///
  /// Held by the view model rather than the tab because the tab is destroyed on every sub-tab
  /// switch and on leaving the screen; see [ComposeDraftMemento]. Assigned without notifying: the
  /// tab reads it when it next mounts, and nothing else observes it, so a notification here would
  /// only rebuild the screen during another widget's dispose.
  ComposeDraftMemento? composeDraft;

  StackSummary? _requestedComposeStack;
  int _composeEditRequest = 0;
  StackSummary? get requestedComposeStack => _requestedComposeStack;
  int get composeEditRequest => _composeEditRequest;

  void requestComposeEdit(StackSummary stack) {
    _requestedComposeStack = stack;
    _composeEditRequest++;
    _activeTab = InfraTab.builder;
    notifyListeners();
  }

  /// Opens a remembered, currently-down stack in the same builder used by a live stack.
  ///
  /// A downed stack has no containers from which to build a [StackSummary], but the registry still
  /// carries all compose-file identity needed by the editor. Converting it here keeps the builder's
  /// import path identical for live and downed stacks.
  void requestDownedComposeEdit(StackRegistryRow stack) {
    requestComposeEdit(
      StackSummary(
        name: stack.project,
        runtime: stack.runtime,
        total: 0,
        running: 0,
        unhealthy: 0,
        restarting: 0,
        restartCount: 0,
        portDetails: const [],
        oldestCreatedAt: '',
        workingDir: stack.workingDir,
        configFiles: stack.configFiles,
        services: const [],
      ),
    );
  }

  // ── loaded state ────────────────────────────────────────────────────────────

  List<SimContainer> _containers = const [];
  List<SimDockerImage> _images = const [];
  List<SimDockerVolume> _volumes = const [];
  List<SimDockerNetwork> _networks = const [];
  List<StackRegistryRow> _downedStacks = const [];
  Set<String> _runtimes = const {};

  List<SimContainer> get containers => _containers;
  List<SimDockerImage> get images => _images;
  List<SimDockerVolume> get volumes => _volumes;
  List<SimDockerNetwork> get networks => _networks;

  /// Runtimes that actually answered `ps` on this host, for the builder's runtime picker.
  Set<String> get runtimes => _runtimes;

  /// Compose projects this app has seen before that have no containers right now — brought down
  /// with `compose down` rather than deleted. Kept so they can be brought back up.
  List<StackRegistryRow> get downedStacks {
    final live = stacks.map((s) => '${s.runtime}\u0000${s.name}').toSet();
    return _downedStacks.where((d) => !live.contains('${d.runtime}\u0000${d.project}')).toList();
  }

  /// Live containers rolled up per compose project.
  List<StackSummary> get stacks => summariseStacks(_containers);

  bool _loading = false;
  String? _error;
  String? _actionOutput;
  String _actionTitle = '';
  bool _actionRunning = false;
  int _actionEpoch = 0;
  SshCancellationToken? _actionCancellation;

  bool get loading => _loading;

  /// True once any probe result is in hand, whichever tab it belongs to.
  ///
  /// Separates a *first* load from a refresh. A progress bar over an empty pane reads as "this host
  /// has none", which is a claim about the host made before anything has been asked of it.
  bool get hasAnyRuntimeData =>
      stacks.isNotEmpty ||
      downedStacks.isNotEmpty ||
      images.isNotEmpty ||
      volumes.isNotEmpty ||
      networks.isNotEmpty;

  /// A transport or runtime failure. Distinct from an empty list, which means the host answered and
  /// genuinely has nothing.
  String? get error => _error;

  /// Combined stdout/stderr of the last action, shown verbatim — compose failures are diagnosed
  /// from their exact wording, so paraphrasing them is worse than useless.
  String? get actionOutput => _actionOutput;
  String get actionTitle => _actionTitle;
  bool get actionRunning => _actionRunning;

  bool _composeBusy = false;
  String? _composeError;

  bool get composeBusy => _composeBusy;
  String? get composeError => _composeError;

  void dismissActionOutput() {
    _actionEpoch++;
    _actionCancellation?.cancel();
    _actionCancellation = null;
    _actionOutput = null;
    _actionTitle = '';
    _actionRunning = false;
    notifyListeners();
  }

  /// Reads an existing Compose file from the currently selected host.
  Future<String?> readComposeFile(String path) async {
    if (path.trim().isEmpty) {
      _composeError = 'Enter the absolute path to a Compose file.';
      _safeNotify();
      return null;
    }
    final serverId = inspectedServer?.id;
    _composeBusy = true;
    _composeError = null;
    _safeNotify();
    try {
      final output = await _exec(composeRead(path.trim()));
      if (inspectedServer?.id != serverId || output == null) return null;
      if (output.trim() == 'OMNITERM_NO_FILE') return '';
      if (output.length > 2 * 1000 * 1000) {
        _composeError = 'Compose file is larger than 2 MB; edit it on the host or split it.';
        return null;
      }
      return output;
    } finally {
      _composeBusy = false;
      _safeNotify();
    }
  }

  /// Validates and deploys the exact file path, with remote rollback on any `up` failure.
  Future<bool> deployCompose({
    required String path,
    required String project,
    required String yaml,
    String workingDir = '',
    String configFiles = '',
    String runtime = '',
  }) async {
    final serverId = inspectedServer?.id;
    if (serverId == null) return false;
    _composeBusy = true;
    _composeError = null;
    _safeNotify();
    try {
      final output = await _exec(
        composeDeploy(
          path,
          project,
          yaml,
          workingDir: workingDir,
          configFiles: configFiles,
          runtime: runtime,
        ),
      );
      if (inspectedServer?.id != serverId || output == null) return false;
      final success = output.contains('OMNITERM_DEPLOY_OK');
      _actionOutput = output.replaceAll('OMNITERM_DEPLOY_OK', '').trim();
      if (_actionOutput!.isEmpty) {
        _actionOutput = success
            ? 'Stack deployed — configuration was already up to date.'
            : 'Deploy failed.';
      }
      if (success) await load();
      return success;
    } finally {
      _composeBusy = false;
      _safeNotify();
    }
  }

  // ── loading ─────────────────────────────────────────────────────────────────

  /// Fetches containers, images, volumes, networks, restart counts and available runtimes.
  ///
  /// The six probes are issued concurrently: they are independent, and serialising them multiplies
  /// the round-trip latency by six on exactly the screen a user opens to check something quickly.
  Future<void> load() async {
    final server = inspectedServer;
    final ssh = transport;
    if (server == null) return;
    if (ssh == null) {
      _error = 'Container inspection is unavailable in this build.';
      _safeNotify();
      return;
    }

    _loading = true;
    _error = null;
    _safeNotify();

    final startedFor = server.id;
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      Future<String> run(String command) => ssh.exec(creds, command);

      final results = await Future.wait([
        run(dockerPsCommand),
        run(dockerRestartsCommand),
        run(dockerImagesCommand),
        run(dockerVolumesCommand),
        run(dockerNetworksCommand),
        run(dockerRuntimesCommand),
      ]);

      // A reply for a host the user has already navigated away from must not be committed.
      if (inspectedServer?.id != startedFor) return;

      final restarts = parseDockerRestartCounts(results[1]);
      final parsed = [
        for (final c in parseDockerPs(results[0])) _withRestartCount(c, server.name, restarts),
      ];

      _containers = parsed;
      _images = [
        for (final image in parseDockerImages(results[2]))
          image..inUse = _imageInUse(image, parsed),
      ];
      _volumes = parseDockerVolumes(results[3]);
      _networks = parseDockerNetworks(results[4]);
      _runtimes = parseRuntimeList(results[5]);

      await _syncStackRegistry(server, parsed);
    } on CredentialResolutionException catch (e) {
      if (inspectedServer?.id == startedFor) _failWith(e.message);
    } catch (e) {
      if (inspectedServer?.id == startedFor) _failWith(e.toString());
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  /// Clears every list alongside the error.
  ///
  /// A transport failure says nothing about what is running on the host, so keeping the previous
  /// lists would present stale rows as current state — and keeping the *registry* rows would report
  /// stacks as "down" on no evidence at all.
  void _failWith(String message) {
    _error = message;
    _containers = const [];
    _images = const [];
    _volumes = const [];
    _networks = const [];
    _downedStacks = const [];
    _runtimes = const {};
  }

  SimContainer _withRestartCount(SimContainer c, String hostName, Map<String, int> restarts) =>
      SimContainer(
        id: c.id,
        name: c.name,
        image: c.image,
        ports: c.ports,
        status: c.status,
        group: c.group,
        host: hostName,
        composeWorkingDir: c.composeWorkingDir,
        composeConfigFiles: c.composeConfigFiles,
        composeService: c.composeService,
        health: c.health,
        // Keyed by runtime first: a Docker and a Podman container can share an id prefix.
        restartCount: restarts['${c.runtime}:${c.id}'] ?? restarts[c.id] ?? c.restartCount,
        createdAt: c.createdAt,
        runtime: c.runtime,
      );

  /// Whether any container uses [image], so the UI can warn before removing one that is in use.
  ///
  /// Matched within the same runtime only, and three ways because a container's image field may be
  /// a bare repository, a `repo:tag`, or an id prefix.
  static bool _imageInUse(SimDockerImage image, List<SimContainer> containers) => containers.any(
    (c) =>
        c.runtime == image.runtime &&
        (c.image == image.repository ||
            c.image == '${image.repository}:${image.tag}' ||
            (image.id.length >= 12 && c.image.contains(image.id.substring(0, 12)))),
  );

  /// Records live compose projects and works out which previously-seen ones are now down.
  ///
  /// Bookkeeping must never break the refresh itself, so failures here are swallowed: a registry
  /// write problem should not blank the container list the user came to see.
  Future<void> _syncStackRegistry(Server server, List<SimContainer> containers) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final live = <String, List<SimContainer>>{};
      for (final c in containers.where((c) => c.group != standaloneGroup)) {
        live.putIfAbsent('${c.runtime}\u0000${c.group}', () => []).add(c);
      }

      final seen = <StackRegistryCompanion>[];
      live.forEach((key, list) {
        final parts = key.split('\u0000');
        final configFiles =
            list.where((c) => c.composeConfigFiles.isNotEmpty).firstOrNull?.composeConfigFiles ??
            '';
        final workingDir = composeStackWorkingDir(
          list.where((c) => c.composeWorkingDir.isNotEmpty).firstOrNull?.composeWorkingDir ?? '',
          configFiles,
        );
        // With no working directory no compose action can ever run for it — including a later
        // "up" — so there is nothing actionable to remember.
        if (workingDir.isEmpty) return;
        seen.add(
          StackRegistryCompanion.insert(
            serverId: server.id,
            runtime: parts[0],
            project: parts[1],
            workingDir: workingDir,
            configFiles: configFiles,
            lastSeenAt: now,
          ),
        );
      });

      if (seen.isNotEmpty) await _app.repository.upsertStacks(seen);
      final known = await _app.repository.getStacksForServer(server.id);
      if (inspectedServer?.id == server.id) {
        _downedStacks = known
            .where((s) => !live.containsKey('${s.runtime}\u0000${s.project}'))
            .toList();
      }
    } catch (_) {
      // Deliberately silent — see the doc comment.
    }
  }

  // ── actions ─────────────────────────────────────────────────────────────────

  Future<void> containerAction(SimContainer container, String action) =>
      _runAction(dockerAction(container.id, action, runtime: container.runtime));

  Future<void> imageAction(SimDockerImage image, String action) =>
      _runAction(dockerImageAction(image.id, action, runtime: image.runtime));

  Future<void> volumeAction(SimDockerVolume volume, String action) =>
      _runAction(dockerVolumeAction(volume.name, action, runtime: volume.runtime));

  Future<void> networkAction(SimDockerNetwork network, String action) =>
      _runAction(dockerNetworkAction(network.id, action, runtime: network.runtime));

  Future<void> pruneImages() => _runAction(dockerPruneImages());

  Future<void> pruneVolumes() => _runAction(dockerPruneVolumes());

  Future<void> pruneNetworks() => _runAction(dockerPruneNetworks());

  /// Runs a compose verb against [stack].
  Future<void> stackAction(
    StackSummary stack,
    String action, {
    String? service,
    int? replicas,
    bool removeOrphans = false,
  }) => _runStreamingAction(
    '${stack.name} · $action',
    dockerComposeAction(
      stack.name,
      stack.workingDir,
      stack.configFiles,
      action,
      service: service,
      replicas: replicas,
      removeOrphans: removeOrphans,
      runtime: stack.runtime,
    ),
  );

  /// The output of the last `logs` request, and which service it came from.
  ///
  /// Kept apart from [actionOutput]: a log dump is something to read, not a one-line result banner,
  /// and putting pages of text through the banner made both useless.
  ({String service, String text})? _serviceLogs;

  ({String service, String text})? get serviceLogs => _serviceLogs;

  void clearServiceLogs() {
    _serviceLogs = null;
    _safeNotify();
  }

  /// Fetches a service's recent log lines for the log sheet.
  Future<void> loadServiceLogs(StackSummary stack, String service) async {
    _serviceLogs = (service: service, text: '');
    _safeNotify();
    final output = await _exec(
      dockerComposeAction(
        stack.name,
        stack.workingDir,
        stack.configFiles,
        'serviceLogs',
        service: service,
        runtime: stack.runtime,
      ),
    );
    if (output == null) {
      _serviceLogs = null;
    } else {
      // An empty answer is a fact about the service, not a failure to ask — said plainly rather
      // than left as an empty sheet that looks like it is still loading.
      _serviceLogs = (
        service: service,
        text: output.trim().isEmpty ? '(this service has logged nothing)' : output,
      );
    }
    _safeNotify();
  }

  /// The published ports of every container backing [service], deduplicated.
  ///
  /// Read from the containers already fetched rather than asked of the host again: `docker ps` has
  /// already told us, and a second round trip could disagree with the list on screen.
  List<String> publishedPortsFor(StackSummary stack, String service) {
    final seen = <String>{};
    for (final container in _containers) {
      if (container.composeService != service) continue;
      if (container.group != stack.name && container.composeWorkingDir != stack.workingDir) {
        continue;
      }
      for (final port in container.ports.split(',')) {
        final trimmed = port.trim();
        // `parseContainers` writes an em dash where docker printed an empty ports column, so that
        // is this app's own word for "publishes nothing" — listing it as a port would be quoting
        // our own placeholder back at the user.
        if (trimmed.isEmpty || trimmed == '—') continue;
        seen.add(trimmed);
      }
    }
    return seen.toList()..sort();
  }

  /// Brings a remembered, currently-down stack back up.
  ///
  /// Checks the compose file still exists first: it can be moved or deleted behind the app's back,
  /// and compose's own missing-file error is confusing. Saying so plainly — and offering to forget
  /// the stack — is more useful than passing that error through.
  Future<void> bringUpDownedStack(StackRegistryRow stack) async {
    final probe = await _exec(composeConfigPresent(stack.workingDir, stack.configFiles));
    if (probe == null) return;
    if (!probe.contains('OMNITERM_COMPOSE_OK')) {
      _actionOutput =
          'The compose file for "${stack.project}" is no longer at '
          '${stack.workingDir}. It may have been moved or deleted.';
      _safeNotify();
      return;
    }
    await _runAction(
      dockerComposeAction(
        stack.project,
        stack.workingDir,
        stack.configFiles,
        'up',
        runtime: stack.runtime,
      ),
    );
  }

  /// Drops a remembered stack from the registry. Purely local — it touches nothing on the host.
  Future<void> forgetDownedStack(StackRegistryRow stack) async {
    await _app.repository.deleteStack(stack.serverId, stack.runtime, stack.project);
    _downedStacks = _downedStacks.where((s) => s.id != stack.id).toList();
    _safeNotify();
  }

  Future<void> _runAction(String command) async {
    final output = await _exec(command);
    if (output != null) {
      _actionOutput = output.trim();
      _safeNotify();
      // Actions change what is running, so the lists are refetched rather than patched locally —
      // guessing the new state is how a UI ends up disagreeing with the host.
      await load();
    }
  }

  Future<void> _runStreamingAction(String title, String command) async {
    final server = inspectedServer;
    final ssh = transport;
    if (server == null) return;
    if (ssh == null) {
      _error = 'Container actions are unavailable in this build.';
      _safeNotify();
      return;
    }
    _actionCancellation?.cancel();
    final token = SshCancellationToken();
    _actionCancellation = token;
    final epoch = ++_actionEpoch;
    _actionTitle = title;
    _actionOutput = '';
    _actionRunning = true;
    _safeNotify();
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final result = await ssh.execStream(
        creds,
        command,
        cancellation: token,
        onChunk: (chunk) async {
          if (epoch != _actionEpoch) return;
          final appended = '${_actionOutput ?? ''}$chunk';
          _actionOutput = appended.length > 200000
              ? '[Earlier output truncated]\n${appended.substring(appended.length - 200000)}'
              : appended;
          _safeNotify();
        },
      );
      if (epoch == _actionEpoch && (_actionOutput ?? '').isEmpty) {
        _actionOutput = result;
      }
    } on CredentialResolutionException catch (error) {
      if (epoch == _actionEpoch) _actionOutput = error.message;
    } catch (error) {
      if (epoch == _actionEpoch) _actionOutput = error.toString();
    } finally {
      if (epoch == _actionEpoch) {
        _actionRunning = false;
        if ((_actionOutput ?? '').trim().isEmpty) {
          _actionOutput = token.isCancelled ? 'Stopped.' : 'Done (no output)';
        }
        _actionCancellation = null;
        _safeNotify();
        await load();
      }
      await token.close();
    }
  }

  /// Runs one command, surfacing failures as [error]. Returns null when it could not run.
  Future<String?> _exec(String command) async {
    final server = inspectedServer;
    final ssh = transport;
    if (server == null) return null;
    if (ssh == null) {
      _error = 'Container actions are unavailable in this build.';
      _safeNotify();
      return null;
    }
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      return await ssh.exec(creds, command);
    } on CredentialResolutionException catch (e) {
      _error = e.message;
      _safeNotify();
      return null;
    } catch (e) {
      _error = e.toString();
      _safeNotify();
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _actionCancellation?.cancel();
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}
