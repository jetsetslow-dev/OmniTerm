import '../../widgets/omni_components.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/infra_view_model.dart';
import '../../widgets/command_output_card.dart';
import '../../widgets/host_selector_bar.dart';
import 'infra_tabs.dart';
import 'compose_builder.dart';

/// The Infra (containers) screen, ported from `InfraScreen` in `ui/InfraScreen.kt`.
///
/// A host picker, five sub-tabs, and a reload. All of the logic — which host is inspected, what each
/// probe returns, the downed-stack registry — lives in [InfraViewModel].
class InfraScreen extends StatefulWidget {
  const InfraScreen({super.key});

  @override
  State<InfraScreen> createState() => _InfraScreenState();
}

class _InfraScreenState extends State<InfraScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred past the first frame: notifying listeners during build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<InfraViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<InfraViewModel>();
    final server = vm.inspectedServer;

    if (server == null) return const _NoOnlineHosts();

    return Column(
      children: [
        _HeaderBar(vm: vm, server: server),
        _TabBar(vm: vm),
        // Only over results already on screen; a first load gets the centred spinner below.
        if (vm.loading && vm.hasAnyRuntimeData) const LinearProgressIndicator(minHeight: 2),
        if (vm.actionOutput != null) _ActionOutput(vm: vm),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: switch (vm.activeTab) {
              // The builder is the one tab that does not depend on a successful probe, so it is
              // reachable even when the runtime could not be queried.
              InfraTab.builder => const BuilderTab(),
              // Ahead of the error branch, as Kotlin orders it: a refresh in flight must not keep
              // showing the previous attempt's failure as though it were the current state.
              _ when vm.loading && !vm.hasAnyRuntimeData => const Center(
                key: ValueKey('infra.firstLoad'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(height: 10),
                    Text('Asking this host about its containers…', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              _ when vm.error != null => _RuntimeError(message: vm.error!),
              InfraTab.stacks => StacksTab(vm: vm),
              InfraTab.images => ImagesTab(vm: vm),
              InfraTab.volumes => VolumesTab(vm: vm),
              InfraTab.networks => NetworksTab(vm: vm),
            },
          ),
        ),
      ],
    );
  }
}

class _NoOnlineHosts extends StatelessWidget {
  const _NoOnlineHosts();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('infra.noHosts'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns, size: 40, color: OmniColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'No online hosts available for container data',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.vm, required this.server});

  final InfraViewModel vm;
  final Server server;

  @override
  Widget build(BuildContext context) {
    // HostDisplay is observable, so it must be listened to — otherwise "Hide sensitive info" would
    // leave this bar showing the host.
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        child: Row(
          children: [
            const Icon(Icons.widgets, size: 18, color: OmniColors.cyan),
            const SizedBox(width: 8),
            Expanded(
              child: HostSelectorBar(
                keyPrefix: 'infra.hostPicker',
                hosts: vm.onlineServers,
                selected: server,
                onChanged: vm.selectServer,
                labelPrefix: 'Containers · ',
              ),
            ),
            IconButton(
              key: const ValueKey('infra.reload'),
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: vm.loading ? null : vm.load,
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.vm});

  final InfraViewModel vm;

  static const _labels = {
    InfraTab.stacks: 'Stacks',
    InfraTab.builder: 'Builder',
    InfraTab.images: 'Images',
    InfraTab.volumes: 'Volumes',
    InfraTab.networks: 'Networks',
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: scaledBarHeight(context, 40),
      child: ListView(
        key: const ValueKey('infra.tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final tab in InfraTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: ChoiceChip(
                  key: ValueKey('infra.tab.${tab.name}'),
                  label: Text(_labels[tab]!, style: const TextStyle(fontSize: 12)),
                  selected: vm.activeTab == tab,
                  onSelected: (_) => vm.activeTab = tab,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The verbatim output of the last action.
class _ActionOutput extends StatelessWidget {
  const _ActionOutput({required this.vm});

  final InfraViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: CommandOutputCard(
        keyPrefix: 'infra.actionOutput',
        title: vm.actionTitle,
        output: vm.actionOutput!,
        running: vm.actionRunning,
        onDismiss: vm.dismissActionOutput,
      ),
    );
  }
}

class _RuntimeError extends StatelessWidget {
  const _RuntimeError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('infra.error'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: OmniColors.red),
          const SizedBox(height: 8),
          const Text('Could not query containers', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(6)),
            padding: const EdgeInsets.all(10),
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Text(
                  message,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontFamily: OmniFonts.mono,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Is Docker or Podman installed, and can this user reach its socket?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
