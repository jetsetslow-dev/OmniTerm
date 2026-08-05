import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/monitor_view_model.dart';
import '../../widgets/health_breakdown_dialog.dart';
import '../../widgets/omni_components.dart';
import 'monitor_tabs.dart';

/// The Monitor screen, ported from `MonitorScreen` in `ui/MonitorScreen.kt`.
///
/// A host selector, six sub-tabs in the Kotlin's order, and a reboot action. All of the logic — which
/// host is shown, what each tab loads, how replies are guarded — lives in [MonitorViewModel].
class MonitorScreen extends StatelessWidget {
  const MonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MonitorViewModel>();
    final server = vm.monitoredServer;

    if (server == null) return const _NoOnlineHosts();

    return Column(
      children: [
        _SelectorBar(vm: vm, server: server),
        _TabBar(vm: vm),
        if (vm.error != null) _ErrorBanner(message: vm.error!),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: switch (vm.activeTab) {
              MonitorTab.overview => OverviewTab(vm: vm, server: server),
              MonitorTab.processes => ProcessesTab(vm: vm),
              MonitorTab.services => ServicesTab(vm: vm),
              MonitorTab.logs => LogsTab(vm: vm),
              MonitorTab.scripts => const _NotYetPorted(name: 'Quick scripts'),
              MonitorTab.cron => const _NotYetPorted(name: 'Cron'),
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
      key: const ValueKey('monitor.noHosts'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 40, color: OmniColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'No online hosts available to monitor',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which host is being monitored, its health ring, and the reboot action.
class _SelectorBar extends StatelessWidget {
  const _SelectorBar({required this.vm, required this.server});

  final MonitorViewModel vm;
  final Server server;

  @override
  Widget build(BuildContext context) {
    final online = context.select<MonitorViewModel, List<Server>>((m) => m.onlineServers);
    final accent = OmniColors.serverAccent(server.serverColor, server.name);

    // HostDisplay is an observable singleton, so it must be listened to rather than merely read —
    // otherwise "Hide sensitive info" would leave this bar showing the address.
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        child: Row(
          children: [
            // The ring is the only place the score appears, and a number between 0 and 100 with no
            // stated reason is not information. Tapping it says which readings cost what.
            InkWell(
              key: const ValueKey('monitor.healthScore.open'),
              onTap: () => showHealthBreakdown(
                context,
                name: HostDisplay.instance.name(server),
                breakdown: vm.healthBreakdown,
              ),
              customBorder: const CircleBorder(),
              child: _ScoreRing(score: server.healthScore, color: accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const ValueKey('monitor.hostPicker'),
                  isExpanded: true,
                  value: server.id,
                  items: [
                    for (final host in online)
                      DropdownMenuItem(
                        value: host.id,
                        child: Text(
                          HostDisplay.instance.name(host),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ),
                  ],
                  onChanged: (id) => vm.selectServer(id),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('monitor.reboot'),
              tooltip: 'Reboot host',
              icon: const Icon(Icons.restart_alt, size: 18, color: OmniColors.red),
              onPressed: () => _confirmReboot(context, vm, server),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReboot(BuildContext context, MonitorViewModel vm, Server server) async {
    // Rebooting is destructive and irreversible from the app's side, so it is always confirmed and
    // the dialog says plainly what will run and what it needs.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('monitor.reboot.dialog'),
        title: Text('Reboot ${server.name}?'),
        content: Text(
          'This runs `sudo reboot` on ${HostDisplay.instance.host(server)}. '
          'The host will drop offline until it comes back up. '
          'Requires sudo rights for the SSH user.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('monitor.reboot.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('monitor.reboot.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reboot', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.rebootMonitoredHost();
  }
}

class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score, required this.color});

  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: (score / 100).clamp(0.0, 1.0),
            strokeWidth: 3,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(
              score >= 70
                  ? OmniColors.green
                  : score >= 40
                  ? OmniColors.amber
                  : OmniColors.red,
            ),
          ),
          Text(
            '$score',
            key: const ValueKey('monitor.healthScore'),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.vm});

  final MonitorViewModel vm;

  static const _labels = {
    MonitorTab.overview: 'Overview',
    MonitorTab.processes: 'Processes',
    MonitorTab.services: 'Services',
    MonitorTab.logs: 'Logs',
    MonitorTab.scripts: 'Scripts',
    MonitorTab.cron: 'CRON',
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        key: const ValueKey('monitor.tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final tab in MonitorTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: ChoiceChip(
                  key: ValueKey('monitor.tab.${tab.name}'),
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OmniCard(
        key: const ValueKey('monitor.error'),
        leftAccent: OmniColors.red,
        child: Text(message, style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono)),
      ),
    );
  }
}

/// Stands in for a tab whose port has not landed yet.
///
/// Named plainly rather than left blank: an empty pane reads as "this host has nothing", which is a
/// different and misleading claim.
class _NotYetPorted extends StatelessWidget {
  const _NotYetPorted({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: ValueKey('monitor.notPorted.$name'),
      child: Text(
        '$name is not available in this build yet.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
      ),
    );
  }
}
