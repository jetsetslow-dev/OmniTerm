import 'dart:async';

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
        // Wraps rather than clipping. At 200% text these figures need 188px more than a phone has,
        // and a summary bar that silently drops its last stat is the one that matters — the online
        // count. A horizontal scroll was the first attempt and is wrong here: the `Spacer` below
        // needs a bounded width, and an unbounded one makes the row fail to lay out at all.
        child: Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
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
            Text(
              'Avg Score: ${vm.averageScore}',
              style: const TextStyle(
                fontSize: 12,
                color: OmniColors.cyan,
                fontWeight: FontWeight.bold,
              ),
            ),
            _RefreshCountdown(vm: vm),
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

/// How long until every host on this screen is measured again.
///
/// The dashboard is a wall of numbers with nothing on it that changes visibly, so without this
/// there is no way to tell a fleet that is idle from one the app stopped polling ten minutes ago.
/// Driven by the poller's own cycle rather than a timer of its own, so it cannot drift away from
/// the thing it describes.
class _RefreshCountdown extends StatefulWidget {
  const _RefreshCountdown({required this.vm});

  final FleetViewModel vm;

  @override
  State<_RefreshCountdown> createState() => _RefreshCountdownState();
}

class _RefreshCountdownState extends State<_RefreshCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = widget.vm.nextRefreshAt;
    // No poller in this build: no countdown, rather than a promise the app cannot keep.
    if (next == null) return const SizedBox.shrink();

    final remaining = next.difference(DateTime.now());
    final label = remaining.isNegative
        ? 'Refreshing now'
        : 'Refreshing in ${remaining.inSeconds + 1} seconds';
    return Semantics(
      key: const ValueKey('fleet.summary.countdown'),
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Text(
          remaining.isNegative ? 'refreshing…' : '${remaining.inSeconds + 1}s',
          style: TextStyle(
            fontSize: 11,
            fontFamily: OmniFonts.mono,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
      // Horizontally scrollable, as the SFTP and Infra tab bars already are: three chips at 200%
      // text do not fit a phone, and an unreachable tab is a feature the user cannot open.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
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
      ),
    );
  }
}
