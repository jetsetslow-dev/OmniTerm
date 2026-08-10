import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_commands.dart';
import '../../../data/remote_models.dart';
import '../../../domain/stack_summary.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/infra_view_model.dart';
import '../../view_model/shell_view_model.dart';
import '../../widgets/omni_components.dart';

/// DOCKER / PODMAN badge.
///
/// A host running both lists each runtime's resources side by side — the same `repo:tag` pulled into
/// each, a `bridge` network per runtime — and nothing else on those rows says which one owns the
/// entry.
class RuntimeTag extends StatelessWidget {
  const RuntimeTag({super.key, required this.runtime});

  final String runtime;

  @override
  Widget build(BuildContext context) {
    if (runtime.isEmpty) return const SizedBox.shrink();
    return OmniTag(
      label: runtime.toUpperCase(),
      color: runtime == 'podman' ? OmniColors.purple : OmniColors.cyan,
    );
  }
}

/// Compose projects, live and remembered-but-down.
class StacksTab extends StatelessWidget {
  const StacksTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  Widget build(BuildContext context) {
    final stacks = vm.stacks;
    final downed = vm.downedStacks;

    if (stacks.isEmpty && downed.isEmpty) {
      return _EmptyTab(
        key: const ValueKey('infra.stacks.empty'),
        icon: Icons.layers_clear,
        message: _emptyMessage(vm, 'compose stacks'),
      );
    }

    return ListView.separated(
      key: const ValueKey('infra.stacks.list'),
      itemCount: stacks.length + downed.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => index < stacks.length
          ? _StackCard(vm: vm, stack: stacks[index])
          : _DownedStackCard(vm: vm, stack: downed[index - stacks.length]),
    );
  }
}

class _StackCard extends StatefulWidget {
  const _StackCard({required this.vm, required this.stack});

  final InfraViewModel vm;
  final StackSummary stack;

  @override
  State<_StackCard> createState() => _StackCardState();
}

class _StackCardState extends State<_StackCard> {
  bool _servicesExpanded = false;

  @override
  Widget build(BuildContext context) {
    final stack = widget.stack;
    final scheme = Theme.of(context).colorScheme;
    final healthy = stack.running == stack.total && stack.unhealthy == 0;

    return OmniCard(
      key: ValueKey('infra.stack.${stack.runtime}.${stack.name}'),
      leftAccent: OmniColors.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.layers, size: 18, color: OmniColors.cyan),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            stack.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              fontFamily: OmniFonts.mono,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        RuntimeTag(runtime: stack.runtime),
                      ],
                    ),
                    Text(
                      // Saying *why* the buttons are absent beats silently omitting them.
                      stack.canRunComposeActions
                          ? stack.workingDir
                          : 'No compose metadata for stack actions',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              OmniTag(
                label: '${stack.running}/${stack.total}',
                color: healthy ? OmniColors.green : OmniColors.amber,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              InkWell(
                key: ValueKey('infra.stack.${stack.name}.ports'),
                onTap: () => _showStackPorts(context, stack),
                child: _Stat(label: 'ports', value: '${stack.exposedPorts}'),
              ),
              if (stack.unhealthy > 0)
                _Stat(label: 'unhealthy', value: '${stack.unhealthy}', color: OmniColors.red),
              if (stack.restarting > 0)
                _Stat(label: 'restarting', value: '${stack.restarting}', color: OmniColors.amber),
              if (stack.restartCount > 0)
                // A stack that is "running" but has restarted hundreds of times is not healthy, and
                // this count is the only place that shows.
                _Stat(
                  label: 'restarts',
                  value: '${stack.restartCount}',
                  color: stack.restartCount > 10 ? OmniColors.amber : null,
                ),
            ],
          ),
          if (stack.canRunComposeActions) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: ValueKey('infra.stack.${stack.name}.editBuilder'),
                onPressed: () => widget.vm.requestComposeEdit(stack),
                icon: const Icon(Icons.edit_note, size: 17),
                label: const Text('Edit in Builder'),
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (action, label) in [
                  ('ps', 'PS'),
                  ('logs', 'Logs'),
                  ('followLogs', 'Follow'),
                  ('config', 'Config'),
                  ('up', 'Up'),
                  ('build', 'Build'),
                  ('restart', 'Restart'),
                  ('pull', 'Pull'),
                  ('update', 'Update'),
                  ('forceRecreate', 'Force recreate'),
                  ('removeOrphans', 'Remove orphans'),
                ])
                  OutlinedButton(
                    key: ValueKey('infra.stack.${stack.name}.$action'),
                    onPressed: () => _stackAction(context, stack, action),
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
                OutlinedButton(
                  key: ValueKey('infra.stack.${stack.name}.down'),
                  onPressed: () => _confirmDown(context, stack),
                  child: const Text('Down', style: TextStyle(fontSize: 12, color: OmniColors.red)),
                ),
              ],
            ),
          ],
          TextButton(
            key: ValueKey('infra.stack.${stack.name}.services'),
            onPressed: () => setState(() => _servicesExpanded = !_servicesExpanded),
            child: Text(
              _servicesExpanded
                  ? 'Hide services'
                  : 'Show ${stack.services.length} service${stack.services.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (_servicesExpanded)
            for (final service in stack.services)
              _ServiceRow(vm: widget.vm, stack: stack, service: service),
        ],
      ),
    );
  }

  Future<void> _stackAction(BuildContext context, StackSummary stack, String action) async {
    final confirmation = switch (action) {
      'build' => (
        'Build ${stack.name}?',
        'Build Dockerfile-based images and refresh their base images. Containers are not '
            'recreated until you run Update or Up.',
        'Build',
      ),
      'update' => (
        'Update ${stack.name}?',
        'Pull images, rebuild Dockerfiles, and recreate this stack?',
        'Update',
      ),
      'forceRecreate' => (
        'Force recreate ${stack.name}?',
        'Recreate every container even when its configuration did not change?',
        'Recreate',
      ),
      'restart' => (
        'Restart ${stack.name}?',
        'All services in this stack will briefly go down.',
        'Restart',
      ),
      'removeOrphans' => (
        'Remove orphan containers?',
        'Remove containers for services no longer defined in ${stack.name}.',
        'Remove orphans',
      ),
      _ => null,
    };
    if (confirmation != null) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: ValueKey('infra.stack.$action.confirm'),
          title: Text(confirmation.$1),
          content: Text(confirmation.$2),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmation.$3),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    await widget.vm.stackAction(stack, action);
  }

  Future<void> _confirmDown(BuildContext context, StackSummary stack) async {
    // `compose down` stops and removes every container in the stack. It is recoverable — the file
    // stays and the registry remembers it — but it is not what a mis-tap should do.
    final removeOrphans = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        var includeOrphans = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            key: const ValueKey('infra.stack.down.dialog'),
            title: Text('Bring down ${stack.name}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stops and removes all ${stack.total} container${stack.total == 1 ? '' : 's'} '
                  'in this stack. Volumes are not removed unless the compose file says so.',
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const ValueKey('infra.stack.down.removeOrphans'),
                  value: includeOrphans,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Remove orphans'),
                  subtitle: const Text(
                    'Also remove containers for services no longer in the compose file.',
                    style: TextStyle(fontSize: 11, color: OmniColors.amber),
                  ),
                  onChanged: (value) => setDialogState(() => includeOrphans = value ?? false),
                ),
              ],
            ),
            actions: [
              TextButton(
                key: const ValueKey('infra.stack.down.cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('infra.stack.down.confirm'),
                onPressed: () => Navigator.of(dialogContext).pop(includeOrphans),
                child: const Text('Bring down', style: TextStyle(color: OmniColors.red)),
              ),
            ],
          ),
        );
      },
    );
    if (removeOrphans != null) {
      await widget.vm.stackAction(stack, 'down', removeOrphans: removeOrphans);
    }
  }
}

Future<void> _showStackPorts(BuildContext context, StackSummary stack) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    key: const ValueKey('infra.stack.ports.dialog'),
    title: Text('${stack.name} ports'),
    content: stack.portDetails.isEmpty
        ? const Text('No published ports were reported for this stack.')
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final detail in stack.portDetails)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${detail.serviceName} · ${detail.containerName}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      Text(
                        detail.ports,
                        style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
    actions: [
      TextButton(
        key: const ValueKey('infra.stack.ports.close'),
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Close'),
      ),
    ],
  ),
);

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.vm, required this.stack, required this.service});

  final InfraViewModel vm;
  final StackSummary stack;
  final StackService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: service.unhealthy > 0
                  ? OmniColors.red
                  : service.running == service.total
                  ? OmniColors.green
                  : OmniColors.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              service.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono),
            ),
          ),
          Text(
            '${service.running}/${service.total}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          if (stack.canRunComposeActions)
            PopupMenuButton<String>(
              key: ValueKey('infra.service.${stack.name}.${service.name}.menu'),
              onSelected: (action) => switch (action) {
                'scale' => _promptScale(context, vm, stack, service),
                'ports' => _showPorts(context, vm, stack, service.name),
                'serviceLogs' => _showServiceLogs(context, vm, stack, service.name),
                'followLogs' => vm.stackAction(stack, 'followLogs', service: service.name),
                'shell' => _openServiceShell(context, vm, stack, service),
                'serviceRestart' ||
                'serviceStop' ||
                'serviceRemove' => _confirmServiceAction(context, vm, stack, service, action),
                _ => vm.stackAction(stack, action, service: service.name),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'serviceRestart', child: Text('Restart')),
                PopupMenuItem(value: 'serviceStop', child: Text('Stop')),
                PopupMenuItem(value: 'scale', child: Text('Scale…')),
                PopupMenuItem(value: 'ports', child: Text('Ports')),
                PopupMenuItem(value: 'serviceLogs', child: Text('Logs')),
                PopupMenuItem(value: 'followLogs', child: Text('Follow logs')),
                PopupMenuItem(value: 'shell', child: Text('Shell')),
                PopupMenuItem(value: 'serviceRemove', child: Text('Remove')),
              ],
            ),
        ],
      ),
    );
  }
}

Future<void> _openServiceShell(
  BuildContext context,
  InfraViewModel vm,
  StackSummary stack,
  StackService service,
) async {
  final server = vm.inspectedServer;
  if (server == null || service.containerId.isEmpty) return;
  final shell = context.read<ShellViewModel>();
  context.read<NavigationController>().navigateTo(Screen.shell);
  await shell.connect(
    server,
    initialCommand: dockerExecShell(service.containerId, runtime: stack.runtime),
  );
}

Future<void> _confirmServiceAction(
  BuildContext context,
  InfraViewModel vm,
  StackSummary stack,
  StackService service,
  String action,
) async {
  final verb = switch (action) {
    'serviceRestart' => 'Restart',
    'serviceStop' => 'Stop',
    'serviceRemove' => 'Remove',
    _ => 'Run',
  };
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: ValueKey('infra.service.$action.confirm'),
      title: Text('$verb ${service.name}?'),
      content: Text(
        action == 'serviceRemove'
            ? 'Stop and remove this service container. Its Compose definition is not deleted.'
            : '$verb this service in ${stack.name}? It will briefly be unavailable.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(verb)),
      ],
    ),
  );
  if (accepted == true) {
    await vm.stackAction(stack, action, service: service.name);
  }
}

/// Asks how many replicas of [service] to run, then scales it.
Future<void> _promptScale(
  BuildContext context,
  InfraViewModel vm,
  StackSummary stack,
  StackService service,
) async {
  final replicas = await showDialog<int>(
    context: context,
    builder: (_) => _ScaleDialog(service: service),
  );
  if (replicas == null) return;
  await vm.stackAction(stack, 'scale', service: service.name, replicas: replicas);
}

/// The replica-count prompt.
///
/// A widget rather than a closure over a controller: a dialog's content outlives the `showDialog`
/// call by the length of its exit animation, and disposing the controller when that call returns
/// throws while the dialog is still fading out.
class _ScaleDialog extends StatefulWidget {
  const _ScaleDialog({required this.service});

  final StackService service;

  @override
  State<_ScaleDialog> createState() => _ScaleDialogState();
}

class _ScaleDialogState extends State<_ScaleDialog> {
  late final _replicas = TextEditingController(text: '${widget.service.total}');

  @override
  void dispose() {
    _replicas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Zero is allowed — draining a service without tearing the stack down is a real thing to want.
    // Negative is not a scale-down, it is a typo.
    final value = int.tryParse(_replicas.text.trim());
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      key: const ValueKey('infra.scale.dialog'),
      title: Text('Scale ${widget.service.name}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Currently ${widget.service.running} of ${widget.service.total} running.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('infra.scale.replicas'),
              controller: _replicas,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Replicas', isDense: true),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              // Said before it runs: `up --scale` is how compose changes a replica count, and it
              // recreates containers whose definition has changed since they started. That is a
              // surprise worth two lines.
              'Runs compose up with a new replica count, which recreates containers whose '
              'definition has changed.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('infra.scale.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('infra.scale.confirm'),
          onPressed: (value ?? -1) < 0 ? null : () => Navigator.of(context).pop(value),
          child: const Text('Scale'),
        ),
      ],
    );
  }
}

/// Lists what [service] publishes to the outside world.
Future<void> _showPorts(
  BuildContext context,
  InfraViewModel vm,
  StackSummary stack,
  String service,
) async {
  final ports = vm.publishedPortsFor(stack, service);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('infra.ports.dialog'),
      title: Text('Ports · $service'),
      content: ports.isEmpty
          ? const SizedBox(
              width: 320,
              child: Text(
                // Not the same as "we could not tell": this service publishes nothing, which is the
                // normal case for a database behind a compose network.
                'This service publishes no ports. It is reachable from other services on the '
                'stack network, but not from outside the host.',
                key: ValueKey('infra.ports.none'),
                style: TextStyle(fontSize: 12),
              ),
            )
          : SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final port in ports)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        port,
                        style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono),
                      ),
                    ),
                ],
              ),
            ),
      actions: [
        TextButton(
          key: const ValueKey('infra.ports.close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Shows a service's recent output in a sheet rather than the one-line result banner.
Future<void> _showServiceLogs(
  BuildContext context,
  InfraViewModel vm,
  StackSummary stack,
  String service,
) async {
  unawaited(vm.loadServiceLogs(stack, service));
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final logs = vm.serviceLogs;
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Logs · ${logs?.service ?? service}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('infra.logs.close'),
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (logs == null || logs.text.isEmpty)
                const Expanded(
                  child: Center(
                    key: ValueKey('infra.logs.loading'),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('infra.logs.text'),
                    padding: const EdgeInsets.all(16),
                    child: SelectionArea(
                      child: Text(
                        logs.text,
                        style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
  vm.clearServiceLogs();
}

/// A stack this app has seen before that has no containers right now.
class _DownedStackCard extends StatelessWidget {
  const _DownedStackCard({required this.vm, required this.stack});

  final InfraViewModel vm;
  final StackRegistryRow stack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OmniCard(
      key: ValueKey('infra.downedStack.${stack.runtime}.${stack.project}'),
      leftAccent: OmniColors.textMuted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.layers_clear, size: 18, color: OmniColors.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            stack.project,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              fontFamily: OmniFonts.mono,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        RuntimeTag(runtime: stack.runtime),
                      ],
                    ),
                    Text(
                      'Down · ${stack.workingDir}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: ValueKey('infra.downedStack.${stack.project}.up'),
                onPressed: () => _confirmUp(context),
                child: const Text('Up', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: ValueKey('infra.downedStack.${stack.project}.editBuilder'),
                  onPressed: () => vm.requestDownedComposeEdit(stack),
                  icon: const Icon(Icons.edit_note, size: 17),
                  label: const Text('Edit in Builder'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: ValueKey('infra.downedStack.${stack.project}.forget'),
                  onPressed: () => _confirmForget(context),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Forget'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmUp(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('infra.downedStack.up.dialog'),
        title: Text('Bring ${stack.project} up?'),
        content: Text(
          'Run compose up from ${stack.workingDir}? Containers and networks are recreated from '
          'the compose file.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Up'),
          ),
        ],
      ),
    );
    if (accepted == true) await vm.bringUpDownedStack(stack);
  }

  Future<void> _confirmForget(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('infra.downedStack.forget.dialog'),
        title: Text('Forget ${stack.project}?'),
        content: const Text(
          'Remove this stack from OmniTerm only. Nothing on the host is touched and the compose '
          'file remains in place.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (accepted == true) await vm.forgetDownedStack(stack);
  }
}

class ImagesTab extends StatefulWidget {
  const ImagesTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  State<ImagesTab> createState() => _ImagesTabState();
}

class _ImagesTabState extends State<ImagesTab> {
  bool _selecting = false;
  Set<String> _selected = {};

  String _key(SimDockerImage image) => '${image.runtime}:${image.id}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vm = widget.vm;

    return Column(
      children: [
        Row(
          children: [
            TextButton(
              key: const ValueKey('infra.images.multiSelect'),
              onPressed: () => setState(() {
                _selecting = !_selecting;
                if (!_selecting) _selected = {};
              }),
              child: Text(_selecting ? 'Cancel selection' : 'Multi-select'),
            ),
            const Spacer(),
            if (_selecting && _selected.isNotEmpty)
              TextButton.icon(
                key: const ValueKey('infra.images.deleteSelected'),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text('Delete ${_selected.length}'),
                onPressed: () => _removeSelected(context),
              ),
            _PruneButton(
              keyName: 'infra.images.prune',
              label: 'Prune unused',
              detail: 'Remove every image no container currently uses. This cannot be undone.',
              onConfirm: vm.pruneImages,
            ),
          ],
        ),
        Expanded(
          child: vm.images.isEmpty
              ? _EmptyTab(
                  key: const ValueKey('infra.images.empty'),
                  icon: Icons.photo_library_outlined,
                  message: _emptyMessage(vm, 'images'),
                )
              : ListView.separated(
                  key: const ValueKey('infra.images.list'),
                  itemCount: vm.images.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final image = vm.images[index];
                    final selected = _selected.contains(_key(image));
                    return OmniCard(
                      key: ValueKey('infra.image.${image.runtime}.${image.id}'),
                      child: Row(
                        children: [
                          if (_selecting)
                            Checkbox(
                              key: ValueKey('infra.image.${image.id}.select'),
                              value: selected,
                              onChanged: (value) => setState(() {
                                value == true
                                    ? _selected.add(_key(image))
                                    : _selected.remove(_key(image));
                              }),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        '${image.repository}:${image.tag}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: OmniFonts.mono,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    RuntimeTag(runtime: image.runtime),
                                  ],
                                ),
                                Text(
                                  'ID: ${image.id} · ${image.size} · ${image.created}',
                                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          if (image.inUse) const OmniTag(label: 'IN USE', color: OmniColors.green),
                          if (!_selecting)
                            IconButton(
                              key: ValueKey('infra.image.${image.id}.remove'),
                              tooltip: 'Remove image',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: OmniColors.red,
                              ),
                              onPressed: () => _confirmRemove(context, image),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmRemove(BuildContext context, SimDockerImage image) async {
    final accepted = await _confirmDestructive(
      context,
      keyName: 'infra.image.remove',
      title: 'Remove image?',
      message: 'Permanently remove ${image.repository}:${image.tag}?',
      confirmLabel: 'Remove',
    );
    if (accepted) await widget.vm.imageAction(image, 'remove');
  }

  Future<void> _removeSelected(BuildContext context) async {
    final accepted = await _confirmDestructive(
      context,
      keyName: 'infra.images.deleteSelected',
      title: 'Remove images?',
      message: 'Permanently remove ${_selected.length} selected images?',
      confirmLabel: 'Remove',
    );
    if (!accepted) return;
    final targets = widget.vm.images.where((image) => _selected.contains(_key(image))).toList();
    for (final image in targets) {
      await widget.vm.imageAction(image, 'remove');
    }
    if (mounted) {
      setState(() {
        _selected = {};
        _selecting = false;
      });
    }
  }
}

class VolumesTab extends StatefulWidget {
  const VolumesTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  State<VolumesTab> createState() => _VolumesTabState();
}

class _VolumesTabState extends State<VolumesTab> {
  bool _selecting = false;
  Set<String> _selected = {};

  String _key(SimDockerVolume volume) => '${volume.runtime}:${volume.name}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vm = widget.vm;

    return Column(
      children: [
        Row(
          children: [
            TextButton(
              key: const ValueKey('infra.volumes.multiSelect'),
              onPressed: () => setState(() {
                _selecting = !_selecting;
                if (!_selecting) _selected = {};
              }),
              child: Text(_selecting ? 'Cancel selection' : 'Multi-select'),
            ),
            const Spacer(),
            if (_selecting && _selected.isNotEmpty)
              TextButton.icon(
                key: const ValueKey('infra.volumes.deleteSelected'),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text('Delete ${_selected.length}'),
                onPressed: () => _removeSelected(context),
              ),
            _PruneButton(
              keyName: 'infra.volumes.prune',
              label: 'Prune unused',
              detail:
                  'Remove every volume no container uses, including named ones. All data in '
                  'them is permanently deleted.',
              onConfirm: vm.pruneVolumes,
            ),
          ],
        ),
        Expanded(
          child: vm.volumes.isEmpty
              ? _EmptyTab(
                  key: const ValueKey('infra.volumes.empty'),
                  icon: Icons.storage,
                  message: _emptyMessage(vm, 'volumes'),
                )
              : ListView.separated(
                  key: const ValueKey('infra.volumes.list'),
                  itemCount: vm.volumes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final volume = vm.volumes[index];
                    return OmniCard(
                      key: ValueKey('infra.volume.${volume.runtime}.${volume.name}'),
                      child: Row(
                        children: [
                          if (_selecting)
                            Checkbox(
                              key: ValueKey('infra.volume.${volume.name}.select'),
                              value: _selected.contains(_key(volume)),
                              onChanged: (value) => setState(() {
                                value == true
                                    ? _selected.add(_key(volume))
                                    : _selected.remove(_key(volume));
                              }),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        volume.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: OmniFonts.mono,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    RuntimeTag(runtime: volume.runtime),
                                  ],
                                ),
                                Text(
                                  [
                                    'Driver: ${volume.driver}',
                                    if (volume.size.isNotEmpty) volume.size,
                                    if (volume.mountpoint.isNotEmpty) volume.mountpoint,
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          if (volume.inUse) const OmniTag(label: 'IN USE', color: OmniColors.green),
                          if (!_selecting)
                            IconButton(
                              key: ValueKey('infra.volume.${volume.name}.remove'),
                              tooltip: 'Remove volume',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: OmniColors.red,
                              ),
                              onPressed: () => _confirmRemove(context, vm, volume),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    InfraViewModel vm,
    SimDockerVolume volume,
  ) async {
    // Unlike a container or an image, a volume is the data. There is nothing to re-pull.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('infra.volume.remove.dialog'),
        title: Text('Delete volume ${volume.name}?'),
        content: const Text('Everything stored in this volume is deleted and cannot be recovered.'),
        actions: [
          TextButton(
            key: const ValueKey('infra.volume.remove.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('infra.volume.remove.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.volumeAction(volume, 'remove');
  }

  Future<void> _removeSelected(BuildContext context) async {
    final accepted = await _confirmDestructive(
      context,
      keyName: 'infra.volumes.deleteSelected',
      title: 'Remove volumes?',
      message: 'Permanently remove ${_selected.length} selected volumes and all data they contain?',
      confirmLabel: 'Remove',
    );
    if (!accepted) return;
    final targets = widget.vm.volumes.where((volume) => _selected.contains(_key(volume))).toList();
    for (final volume in targets) {
      await widget.vm.volumeAction(volume, 'remove');
    }
    if (mounted) {
      setState(() {
        _selected = {};
        _selecting = false;
      });
    }
  }
}

class NetworksTab extends StatelessWidget {
  const NetworksTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _PruneButton(
            keyName: 'infra.networks.prune',
            label: 'Prune unused',
            detail: 'Remove all networks that no container uses. This cannot be undone.',
            onConfirm: vm.pruneNetworks,
          ),
        ),
        Expanded(
          child: vm.networks.isEmpty
              ? _EmptyTab(
                  key: const ValueKey('infra.networks.empty'),
                  icon: Icons.lan_outlined,
                  message: _emptyMessage(vm, 'networks'),
                )
              : ListView.separated(
                  key: const ValueKey('infra.networks.list'),
                  itemCount: vm.networks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final network = vm.networks[index];
                    final builtIn = const {
                      'bridge',
                      'host',
                      'none',
                      'podman',
                    }.contains(network.name);
                    return OmniCard(
                      key: ValueKey('infra.network.${network.runtime}.${network.id}'),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        network.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: OmniFonts.mono,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    RuntimeTag(runtime: network.runtime),
                                  ],
                                ),
                                Text(
                                  [
                                    'Driver: ${network.driver}',
                                    if (network.subnet.isNotEmpty) 'Subnet: ${network.subnet}',
                                    if (network.gateway.isNotEmpty) 'GW: ${network.gateway}',
                                    '${network.containerCount} container${network.containerCount == 1 ? '' : 's'}',
                                    network.id.length > 12
                                        ? network.id.substring(0, 12)
                                        : network.id,
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          if (builtIn)
                            const OmniTag(label: 'BUILT-IN', color: OmniColors.textMuted)
                          else
                            IconButton(
                              key: ValueKey('infra.network.${network.id}.remove'),
                              tooltip: 'Remove network',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: OmniColors.red,
                              ),
                              onPressed: () => _confirmRemoveNetwork(context, vm, network),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Future<void> _confirmRemoveNetwork(
  BuildContext context,
  InfraViewModel vm,
  SimDockerNetwork network,
) async {
  final accepted = await _confirmDestructive(
    context,
    keyName: 'infra.network.remove',
    title: 'Remove network?',
    message: 'Permanently remove network ${network.name}?',
    confirmLabel: 'Remove',
  );
  if (accepted) await vm.networkAction(network, 'remove');
}

class _PruneButton extends StatelessWidget {
  const _PruneButton({
    required this.keyName,
    required this.label,
    required this.detail,
    required this.onConfirm,
  });

  final String keyName;
  final String label;
  final String detail;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: ValueKey(keyName),
      icon: const Icon(Icons.cleaning_services, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: ValueKey('$keyName.dialog'),
            title: Text(label),
            content: Text(detail),
            actions: [
              TextButton(
                key: ValueKey('$keyName.cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: ValueKey('$keyName.confirm'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Prune', style: TextStyle(color: OmniColors.red)),
              ),
            ],
          ),
        );
        if (confirmed ?? false) await onConfirm();
      },
    );
  }
}

Future<bool> _confirmDestructive(
  BuildContext context, {
  required String keyName,
  required String title,
  required String message,
  required String confirmLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: ValueKey('$keyName.dialog'),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            key: ValueKey('$keyName.cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: ValueKey('$keyName.confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      '$value $label',
      style: TextStyle(
        fontSize: 11,
        fontFamily: OmniFonts.mono,
        color: color ?? scheme.onSurfaceVariant,
      ),
    );
  }
}

/// What an empty container tab should say.
///
/// "No images on this host" and "this host has no container runtime" are different facts, and the
/// second is the one that explains the first. Reporting only the first sends the user looking for
/// stacks on a machine that could not run one — the same confusion §15.10 fixed for logs.
String _emptyMessage(InfraViewModel vm, String noun) => vm.runtimes.isEmpty
    ? 'No container runtime on this host. Docker or Podman has to be installed and running before '
          'OmniTerm can list $noun.'
    : 'No $noun on this host';

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: OmniColors.textMuted),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
