import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/fleet_view_model.dart';
import 'fleet_tabs.dart';

/// The Fleet screen, ported from `FleetScreen` in `ui/FleetScreen.kt`.
///
/// A fleet-wide summary, then three tabs: Dashboard, Broadcast, Logs.
class FleetScreen extends StatelessWidget {
  const FleetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<FleetViewModel>();

    return Column(
      children: [
        _SummaryBar(vm: vm),
        _TabBar(vm: vm),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: switch (vm.activeTab) {
              FleetTab.dashboard => FleetDashboardTab(vm: vm),
              FleetTab.broadcast => FleetBroadcastTab(vm: vm),
              FleetTab.logs => FleetLogsTab(vm: vm),
            },
          ),
        ),
      ],
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        key: const ValueKey('fleet.summary'),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Text(
              'FLEET',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontFamily: OmniFonts.mono,
                fontSize: 15,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Avg Score: ${vm.averageScore}',
              style: const TextStyle(
                fontSize: 12,
                color: OmniColors.cyan,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Text(
              '${vm.onlineCount} / ${vm.totalCount} Online',
              key: const ValueKey('fleet.summary.online'),
              style: TextStyle(
                fontSize: 12,
                // Red the moment any online host is in trouble — the count alone would read as
                // healthy while a machine is falling over.
                color: vm.criticalCount > 0 ? OmniColors.red : OmniColors.green,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.vm});

  final FleetViewModel vm;

  static const _labels = {
    FleetTab.dashboard: 'Dashboard',
    FleetTab.broadcast: 'Broadcast',
    FleetTab.logs: 'Logs',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        key: const ValueKey('fleet.tabs'),
        children: [
          for (final tab in FleetTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: ValueKey('fleet.tab.${tab.name}'),
                label: Text(_labels[tab]!, style: const TextStyle(fontSize: 12)),
                selected: vm.activeTab == tab,
                onSelected: (_) => vm.activeTab = tab,
              ),
            ),
        ],
      ),
    );
  }
}
