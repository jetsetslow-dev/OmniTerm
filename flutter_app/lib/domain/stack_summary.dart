import '../data/remote_models.dart';
import '../data/remote_parsers.dart';

/// One container within a compose service.
class StackContainer {
  const StackContainer({required this.name, required this.status, required this.ports});

  final String name;
  final String status;
  final String ports;
}

/// One compose service — usually one container, more when the service is scaled.
class StackService {
  const StackService({
    required this.name,
    required this.total,
    required this.running,
    required this.unhealthy,
    required this.containerId,
    required this.containers,
  });

  final String name;
  final int total;
  final int running;
  final int unhealthy;

  /// The container an action targets: a running one when there is one, else any.
  final String containerId;

  final List<StackContainer> containers;
}

/// A published port, kept with the service that owns it.
class ContainerPortDetail {
  const ContainerPortDetail({
    required this.containerName,
    required this.serviceName,
    required this.ports,
  });

  final String containerName;
  final String serviceName;
  final String ports;
}

/// A compose project's containers rolled up into one row.
class StackSummary {
  const StackSummary({
    required this.name,
    required this.runtime,
    required this.total,
    required this.running,
    required this.unhealthy,
    required this.restarting,
    required this.restartCount,
    required this.portDetails,
    required this.oldestCreatedAt,
    required this.workingDir,
    required this.configFiles,
    required this.services,
  });

  final String name;

  /// "docker" or "podman".
  final String runtime;

  final int total;
  final int running;
  final int unhealthy;
  final int restarting;

  /// Total restarts across the stack — a stack that is "running" but has restarted 400 times is not
  /// healthy, and the count is the only place that shows.
  final int restartCount;

  final List<ContainerPortDetail> portDetails;
  final String oldestCreatedAt;
  final String workingDir;
  final String configFiles;
  final List<StackService> services;

  int get exposedPorts => portDetails.length;

  /// True when compose actions (up/down/restart/pull) can run for this stack.
  ///
  /// Standalone containers have no project to act on, and a stack whose working directory could not
  /// be resolved has nowhere to `cd` — offering the buttons anyway produces a command that fails on
  /// the host for reasons the user cannot see.
  bool get canRunComposeActions => name != standaloneGroup && workingDir.isNotEmpty;
}

/// The group name the parser gives containers that belong to no compose project.
const standaloneGroup = 'standalone';

/// Rolls a flat container list into one row per compose project, ported from the `stacks` block in
/// `StacksView` (`ui/InfraScreen.kt` line 174).
///
/// Grouped by **(runtime, project)**, not project alone: a host running both Docker and Podman can
/// have a project of the same name under each, and merging them would show one row whose actions
/// would hit whichever runtime happened to sort first.
List<StackSummary> summariseStacks(List<SimContainer> containers) {
  final groups = <(String, String), List<SimContainer>>{};
  for (final container in containers) {
    groups.putIfAbsent((container.runtime, container.group), () => []).add(container);
  }

  final stacks = <StackSummary>[];
  groups.forEach((key, list) {
    final (runtime, name) = key;

    final portDetails = [
      for (final c in list.where((c) => c.ports != '—'))
        ContainerPortDetail(
          containerName: c.name,
          serviceName: serviceNameOf(c),
          ports: c.ports,
        ),
    ];

    final byService = <String, List<SimContainer>>{};
    for (final container in list) {
      byService.putIfAbsent(serviceNameOf(container), () => []).add(container);
    }

    final services = byService.entries.map((entry) {
      final serviceContainers = entry.value;
      return StackService(
        name: entry.key.isEmpty ? 'service' : entry.key,
        total: serviceContainers.length,
        running: serviceContainers.where((c) => c.status == 'running').length,
        unhealthy: serviceContainers.where((c) => c.health == 'unhealthy').length,
        // A running container is the one worth acting on; an exited one is only a fallback so the
        // row still has a target.
        containerId: serviceContainers
                .where((c) => c.status == 'running')
                .firstOrNull
                ?.id ??
            serviceContainers.firstOrNull?.id ??
            '',
        containers: [
          for (final c in serviceContainers)
            StackContainer(name: c.name, status: c.status, ports: c.ports),
        ],
      );
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final created = list.map((c) => c.createdAt).where((t) => t.isNotEmpty).toList()..sort();

    stacks.add(
      StackSummary(
        name: name,
        runtime: runtime,
        total: list.length,
        running: list.where((c) => c.status == 'running').length,
        unhealthy: list.where((c) => c.health == 'unhealthy').length,
        restarting: list.where((c) => c.status == 'restarting').length,
        restartCount: list.fold(0, (sum, c) => sum + c.restartCount),
        portDetails: portDetails,
        oldestCreatedAt: created.firstOrNull ?? '',
        // podman-compose often sets config_files but not working_dir; the helper falls back to the
        // first absolute config file's parent — the directory compose would cd into anyway.
        workingDir: composeStackWorkingDir(
          list.where((c) => c.composeWorkingDir.isNotEmpty).firstOrNull?.composeWorkingDir ?? '',
          list.where((c) => c.composeConfigFiles.isNotEmpty).firstOrNull?.composeConfigFiles ?? '',
        ),
        configFiles:
            list.where((c) => c.composeConfigFiles.isNotEmpty).firstOrNull?.composeConfigFiles ?? '',
        services: services,
      ),
    );
  });

  return stacks;
}

/// The compose service a container belongs to.
///
/// Falls back to the part of the container name before the first `_`, which is how compose names
/// containers (`project_service_1`) when the label is missing — as it is on older engines and for
/// containers started by hand.
String serviceNameOf(SimContainer container) => container.composeService.isNotEmpty
    ? container.composeService
    : container.name.split('_').first;

/// The absolute path of the compose file a stack was created from.
///
/// Config-file labels may be absolute or relative, and may list several files; the first is the one
/// compose treats as primary. A stack with no label at all falls back to the conventional name in
/// its working directory.
String composeFilePathFor({required String workingDir, required String configFiles}) {
  final first = configFiles
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .firstOrNull ??
      '';
  final base = workingDir.endsWith('/')
      ? workingDir.substring(0, workingDir.length - 1)
      : workingDir;
  if (first.startsWith('/')) return first;
  if (first.isNotEmpty) return '$base/$first';
  return '$base/docker-compose.yml';
}
