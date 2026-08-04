import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../../domain/stack_summary.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/infra_view_model.dart';
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
        message: 'No compose stacks found on this host',
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
              _Stat(label: 'ports', value: '${stack.exposedPorts}'),
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
            Wrap(
              spacing: 6,
              children: [
                for (final (action, label) in [
                  ('up', 'Up'),
                  ('restart', 'Restart'),
                  ('pull', 'Pull'),
                  ('update', 'Update'),
                ])
                  OutlinedButton(
                    key: ValueKey('infra.stack.${stack.name}.$action'),
                    onPressed: () => widget.vm.stackAction(stack, action),
                    child: Text(label, style: const TextStyle(fontSize: 12)),
                  ),
                OutlinedButton(
                  key: ValueKey('infra.stack.${stack.name}.down'),
                  onPressed: () => _confirmDown(context, stack),
                  child: const Text(
                    'Down',
                    style: TextStyle(fontSize: 12, color: OmniColors.red),
                  ),
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

  Future<void> _confirmDown(BuildContext context, StackSummary stack) async {
    // `compose down` stops and removes every container in the stack. It is recoverable — the file
    // stays and the registry remembers it — but it is not what a mis-tap should do.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('infra.stack.down.dialog'),
        title: Text('Bring down ${stack.name}?'),
        content: Text(
          'Stops and removes all ${stack.total} container${stack.total == 1 ? '' : 's'} in this '
          'stack. The compose file stays, so it can be brought back up.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('infra.stack.down.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('infra.stack.down.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Bring down', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await widget.vm.stackAction(stack, 'down');
  }
}

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
              onSelected: (action) =>
                  vm.stackAction(stack, action, service: service.name),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'serviceRestart', child: Text('Restart')),
                PopupMenuItem(value: 'serviceStop', child: Text('Stop')),
                PopupMenuItem(value: 'serviceLogs', child: Text('Logs')),
              ],
            ),
        ],
      ),
    );
  }
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
      child: Row(
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
            onPressed: () => vm.bringUpDownedStack(stack),
            child: const Text('Up', style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            key: ValueKey('infra.downedStack.${stack.project}.forget'),
            tooltip: 'Forget this stack',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => vm.forgetDownedStack(stack),
          ),
        ],
      ),
    );
  }
}

class ImagesTab extends StatelessWidget {
  const ImagesTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.images.isEmpty) {
      return _EmptyTab(
        key: const ValueKey('infra.images.empty'),
        icon: Icons.photo_library_outlined,
        message: 'No images on this host',
      );
    }

    return Column(
      children: [
        _PruneRow(
          keyName: 'infra.images.prune',
          label: 'Prune unused images',
          detail: 'Removes every image no container is using.',
          onConfirm: vm.pruneImages,
        ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('infra.images.list'),
            itemCount: vm.images.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final image = vm.images[index];
              return OmniCard(
                key: ValueKey('infra.image.${image.runtime}.${image.id}'),
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
                            '${image.size} · ${image.created}',
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (image.inUse)
                      const OmniTag(label: 'IN USE', color: OmniColors.green)
                    else
                      IconButton(
                        key: ValueKey('infra.image.${image.id}.remove'),
                        tooltip: 'Remove image',
                        icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
                        onPressed: () => vm.imageAction(image, 'remove'),
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

class VolumesTab extends StatelessWidget {
  const VolumesTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.volumes.isEmpty) {
      return _EmptyTab(
        key: const ValueKey('infra.volumes.empty'),
        icon: Icons.storage,
        message: 'No volumes on this host',
      );
    }

    return Column(
      children: [
        _PruneRow(
          keyName: 'infra.volumes.prune',
          label: 'Prune unused volumes',
          // Volumes hold data, so this warning is stronger than the images one on purpose.
          detail: 'Removes every volume no container is using, including named ones. '
              'Any data in them is deleted and cannot be recovered.',
          onConfirm: vm.pruneVolumes,
        ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('infra.volumes.list'),
            itemCount: vm.volumes.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final volume = vm.volumes[index];
              return OmniCard(
                key: ValueKey('infra.volume.${volume.runtime}.${volume.name}'),
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
                            [volume.driver, if (volume.size.isNotEmpty) volume.size].join(' · '),
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (volume.inUse)
                      const OmniTag(label: 'IN USE', color: OmniColors.green)
                    else
                      IconButton(
                        key: ValueKey('infra.volume.${volume.name}.remove'),
                        tooltip: 'Remove volume',
                        icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
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
        content: const Text(
          'Everything stored in this volume is deleted and cannot be recovered.',
        ),
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
}

class NetworksTab extends StatelessWidget {
  const NetworksTab({super.key, required this.vm});

  final InfraViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.networks.isEmpty) {
      return _EmptyTab(
        key: const ValueKey('infra.networks.empty'),
        icon: Icons.lan_outlined,
        message: 'No networks on this host',
      );
    }

    return ListView.separated(
      key: const ValueKey('infra.networks.list'),
      itemCount: vm.networks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final network = vm.networks[index];
        // Removing these breaks container networking on the host and they cannot be recreated
        // identically, so they get no delete button at all.
        final builtIn = const {'bridge', 'host', 'none', 'podman'}.contains(network.name);
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
                            style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 6),
                        RuntimeTag(runtime: network.runtime),
                      ],
                    ),
                    Text(
                      [
                        network.driver,
                        if (network.subnet.isNotEmpty) network.subnet,
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
                  icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
                  onPressed: () => vm.networkAction(network, 'remove'),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PruneRow extends StatelessWidget {
  const _PruneRow({
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
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
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
      ),
    );
  }
}

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
