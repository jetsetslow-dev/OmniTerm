import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/fleet_view_model.dart';
import '../../view_model/scripts_view_model.dart';
import '../../widgets/health_breakdown_dialog.dart';
import '../../widgets/metric_line_chart.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/run_command_dialog.dart';

/// Every host at a glance, worst first.
class FleetDashboardTab extends StatelessWidget {
  const FleetDashboardTab({super.key, required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.servers.isEmpty) {
      return Center(
        key: const ValueKey('fleet.dashboard.empty'),
        child: Text(
          'No hosts yet — add one on the Hosts tab.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      );
    }

    // Worst score first: the reason to open a fleet dashboard is to find what needs attention, and
    // a name-sorted list buries it.
    final ordered = [...vm.servers]
      ..sort((a, b) {
        if (a.status != b.status) return a.status == 'online' ? -1 : 1;
        return a.healthScore.compareTo(b.healthScore);
      });

    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => ListView.separated(
        key: const ValueKey('fleet.dashboard.list'),
        itemCount: ordered.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _HostCard(vm: vm, server: ordered[index]),
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.vm, required this.server});

  final FleetViewModel vm;
  final Server server;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = HostDisplay.instance;
    final online = server.status == 'online';
    final scoreColor = !online
        ? OmniColors.textMuted
        : server.healthScore >= 70
        ? OmniColors.green
        : server.healthScore >= 50
        ? OmniColors.amber
        : OmniColors.red;

    final accent = OmniColors.serverAccent(server.serverColor, server.name);

    return OmniCard(
      key: ValueKey('fleet.host.${server.id}'),
      leftAccent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      display.name(server),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    Text(
                      display.userAtHost(server),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: OmniFonts.mono,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (online)
                // Tappable for the same reason as Monitor's ring: a score with no stated reason is not
                // information. Only for an online host — there is nothing to explain about a number
                // that is not being computed.
                InkWell(
                  key: ValueKey('fleet.host.${server.id}.score.open'),
                  onTap: () => showHealthBreakdown(
                    context,
                    name: display.name(server),
                    breakdown: vm.healthBreakdownFor(server),
                  ),
                  child: Semantics(
                    label: 'Health score: ${server.healthScore} out of 100',
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        '${server.healthScore}',
                        key: ValueKey('fleet.host.${server.id}.score'),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          fontFamily: OmniFonts.mono,
                          color: scoreColor,
                        ),
                      ),
                    ),
                  ),
                )
              else
                // A score for an unreachable host is a stale number pretending to be current.
                const OmniTag(label: 'OFFLINE', color: OmniColors.textMuted),
            ],
          ),
          // The dashboard's whole job is comparing hosts, and a column of bare numbers cannot show
          // which machine is climbing. An offline host gets no chart: its series stopped, and a
          // line ending mid-air would read as current.
          if (online) ...[
            const SizedBox(height: 10),
            MetricLineChart(
              key: ValueKey('fleet.host.${server.id}.chart'),
              points: vm.cpuHistoryFor(server.id),
              timestamps: vm.historyTimestampsFor(server.id),
              color: accent,
              label: 'CPU',
            ),
          ],
        ],
      ),
    );
  }
}

/// Run one command across many hosts.
class FleetBroadcastTab extends StatefulWidget {
  const FleetBroadcastTab({super.key, required this.vm});

  final FleetViewModel vm;

  @override
  State<FleetBroadcastTab> createState() => _FleetBroadcastTabState();
}

class _FleetBroadcastTabState extends State<FleetBroadcastTab> {
  late final TextEditingController _controller = TextEditingController(text: widget.vm.commandText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final scheme = Theme.of(context).colorScheme;
    final targets = vm.resolvedTargets;

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<FleetTargetMode>(
              key: const ValueKey('fleet.targetMode'),
              segments: const [
                ButtonSegment(value: FleetTargetMode.servers, label: Text('Hosts')),
                ButtonSegment(value: FleetTargetMode.groups, label: Text('Groups')),
              ],
              selected: {vm.targetMode},
              onSelectionChanged: (s) => vm.targetMode = s.first,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: vm.targetMode == FleetTargetMode.servers
                  ? _HostTargets(vm: vm)
                  : _GroupTargets(vm: vm),
            ),
            const SizedBox(height: 8),
            _PresetRow(
              onPick: (command) {
                _controller.text = command;
                vm.commandText = command;
              },
            ),
            TextField(
              key: const ValueKey('fleet.command'),
              controller: _controller,
              onChanged: (value) => vm.commandText = value,
              style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
              decoration: omniInputDecoration(
                context,
                hintText: 'Command to run on every target',
                prefixIcon: const Icon(Icons.terminal, size: 18),
              ),
            ),
            if (vm.dangerWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, size: 16, color: OmniColors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        vm.dangerWarning!,
                        key: const ValueKey('fleet.dangerWarning'),
                        style: const TextStyle(fontSize: 11, color: OmniColors.amber),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${targets.length} target${targets.length == 1 ? '' : 's'}',
                  key: const ValueKey('fleet.targetCount'),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                if (vm.results.isNotEmpty && !vm.executing)
                  TextButton(
                    key: const ValueKey('fleet.clearResults'),
                    onPressed: vm.clearResults,
                    child: const Text('Clear', style: TextStyle(fontSize: 12)),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey('fleet.run'),
                  onPressed: vm.executing
                      ? vm.cancelBroadcast
                      : vm.canRun
                      ? () => _confirmAndRun(context, vm)
                      : null,
                  icon: vm.executing
                      ? const Icon(Icons.stop, size: 18)
                      : const Icon(Icons.play_arrow, size: 18),
                  label: Text(vm.executing ? 'Cancel' : 'Run'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Not `Expanded`. The form above is taller than a landscape phone at 200% text, so
            // `Expanded` was handed nothing and the column overflowed by 25px. Sized to what is left,
            // with a floor: the results list scrolls internally, and a pane too short to show one row
            // is worse than a form the user has to scroll to.
            SizedBox(
              height: (constraints.maxHeight * 0.35).clamp(120.0, constraints.maxHeight),
              child: vm.results.isEmpty
                  ? Center(
                      key: const ValueKey('fleet.broadcast.idle'),
                      child: Text(
                        vm.canBroadcast
                            ? 'Pick targets, type a command, and Run.'
                            : 'Broadcasting is unavailable in this build.',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      key: const ValueKey('fleet.results'),
                      itemCount: vm.results.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => _ResultCard(result: vm.results[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms, then runs exactly the list that was approved.
  ///
  /// The targets are snapshotted at tap time and passed through, so group membership and
  /// reachability are not re-resolved behind the dialog.
  Future<void> _confirmAndRun(BuildContext context, FleetViewModel vm) async {
    final targets = vm.resolvedTargets;
    final command = vm.commandText.trim();
    final confirmed = await confirmRunCommand(
      context,
      command: command,
      targets: targets,
      danger: vm.dangerWarning,
    );
    if (confirmed) await vm.runBroadcast(targets);
  }
}

class _HostTargets extends StatelessWidget {
  const _HostTargets({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final online = vm.onlineServers;
    if (online.isEmpty) {
      return Center(
        key: const ValueKey('fleet.targets.none'),
        child: Text(
          'No online hosts to target',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      key: const ValueKey('fleet.targets.hosts'),
      scrollDirection: Axis.horizontal,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Center(
            child: ActionChip(
              key: const ValueKey('fleet.targets.all'),
              label: const Text('All', style: TextStyle(fontSize: 11)),
              onPressed: vm.selectAllTargets,
            ),
          ),
        ),
        for (final server in online)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: FilterChip(
                key: ValueKey('fleet.target.${server.id}'),
                label: Text(server.name, style: const TextStyle(fontSize: 11)),
                selected: vm.targetServerIds.contains(server.id),
                onSelected: (_) => vm.toggleTargetServer(server.id),
              ),
            ),
          ),
      ],
    );
  }
}

class _GroupTargets extends StatelessWidget {
  const _GroupTargets({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final groups = vm.groups;
    if (groups.isEmpty) {
      return Center(
        key: const ValueKey('fleet.targets.noGroups'),
        child: Text(
          'No groups among online hosts',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      key: const ValueKey('fleet.targets.groups'),
      scrollDirection: Axis.horizontal,
      children: [
        for (final group in groups)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: FilterChip(
                key: ValueKey('fleet.targetGroup.$group'),
                label: Text(group, style: const TextStyle(fontSize: 11)),
                selected: vm.targetGroups.contains(group),
                onSelected: (_) => vm.toggleTargetGroup(group),
              ),
            ),
          ),
      ],
    );
  }
}

class _ResultCard extends StatefulWidget {
  const _ResultCard({required this.result});

  final BroadcastResult result;

  @override
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (result.status) {
      BroadcastStatus.pending => (OmniColors.textMuted, 'QUEUED'),
      BroadcastStatus.running => (OmniColors.cyan, 'RUNNING'),
      BroadcastStatus.success => (OmniColors.green, 'OK'),
      BroadcastStatus.failure => (OmniColors.red, 'FAILED'),
      BroadcastStatus.cancelled => (OmniColors.amber, 'CANCELLED'),
    };
    final body = result.output.toString().trim();

    return OmniCard(
      key: ValueKey('fleet.result.${result.serverId}'),
      leftAccent: color,
      onTap: () => setState(() => _collapsed = !_collapsed),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  result.serverName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              if (result.status == BroadcastStatus.running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(width: 8),
              OmniTag(label: label, color: color),
            ],
          ),
          if (result.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                result.note!,
                style: TextStyle(
                  fontSize: 11,
                  color: result.status == BroadcastStatus.failure
                      ? OmniColors.red
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (body.isNotEmpty && !_collapsed) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                // Selectable: broadcast output is the raw evidence a user reasons from.
                child: SelectionArea(
                  child: Text(
                    body,
                    style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Logs from several hosts, merged.
class FleetLogsTab extends StatelessWidget {
  const FleetLogsTab({super.key, required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = vm.onlineServers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: online.isEmpty
              ? Center(
                  child: Text(
                    'No online hosts',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  key: const ValueKey('fleet.logs.hosts'),
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final server in online)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Center(
                          child: FilterChip(
                            key: ValueKey('fleet.logs.host.${server.id}'),
                            label: Text(server.name, style: const TextStyle(fontSize: 11)),
                            selected: vm.logServerIds.contains(server.id),
                            onSelected: (_) => vm.toggleLogServer(server.id),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 4,
                children: [
                  for (final level in ['ALL', 'INFO', 'WARN', 'ERROR'])
                    ChoiceChip(
                      key: ValueKey('fleet.logs.filter.$level'),
                      label: Text(level, style: const TextStyle(fontSize: 11)),
                      selected: vm.logLevelFilter == level,
                      onSelected: (_) => vm.logLevelFilter = level,
                    ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('fleet.logs.reload'),
              tooltip: 'Fetch logs',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: vm.logsLoading ? null : vm.loadLogs,
            ),
          ],
        ),
        if (vm.logsLoading) const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            color: Colors.black,
            padding: const EdgeInsets.all(8),
            child: vm.logs.isEmpty
                ? Center(
                    key: const ValueKey('fleet.logs.empty'),
                    child: Text(
                      vm.logServerIds.isEmpty
                          ? 'Pick hosts, then fetch their logs.'
                          : 'No matching log lines.',
                      style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      key: const ValueKey('fleet.logs.list'),
                      itemCount: vm.logs.length,
                      itemBuilder: (context, index) {
                        final entry = vm.logs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 68,
                                // The host name leads: in a merged view, which machine a line came
                                // from is the first thing you need.
                                child: Text(
                                  entry.serverName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: OmniColors.cyan,
                                    fontFamily: OmniFonts.mono,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 44,
                                child: Text(
                                  entry.level,
                                  style: TextStyle(
                                    color: switch (entry.level) {
                                      'ERROR' => OmniColors.red,
                                      'WARN' => OmniColors.amber,
                                      _ => Colors.white70,
                                    },
                                    fontFamily: OmniFonts.mono,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.message,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: OmniFonts.mono,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// Saved fleet commands, offered as one-tap presets.
///
/// Reads the scripts store directly rather than duplicating a command list here: the same rows the
/// Scripts tool manages are what Fleet should offer, and a second copy would drift from it.
class _PresetRow extends StatefulWidget {
  const _PresetRow({required this.onPick});

  final void Function(String command) onPick;

  @override
  State<_PresetRow> createState() => _PresetRowState();
}

class _PresetRowState extends State<_PresetRow> {
  /// Narrows the row. Only shown once there are enough presets for scrolling to be worse than
  /// typing — below that the filter is more work than the thing it filters.
  static const _searchAppearsAbove = 6;

  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ScriptsViewModel>().start();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = context.watch<ScriptsViewModel>().fleetPresetScripts;
    if (all.isEmpty) return const SizedBox.shrink();

    final query = _search.text.trim().toLowerCase();
    // Matched against the command too: half of what makes a saved command recognisable is what it
    // runs, and someone hunting for the one with `journalctl` in it should find it.
    final scripts = query.isEmpty
        ? all
        : all
              .where(
                (s) =>
                    s.name.toLowerCase().contains(query) || s.command.toLowerCase().contains(query),
              )
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (all.length > _searchAppearsAbove)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextField(
              key: const ValueKey('fleet.presets.search'),
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                hintText: 'Filter ${all.length} saved commands',
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        key: const ValueKey('fleet.presets.search.clear'),
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (_) => setState(() {}),
            ),
          ),
        if (scripts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              // "Nothing matched" and "you have none saved" are different facts; the second is
              // handled by the early return above.
              'No saved command matches "${_search.text.trim()}".',
              key: const ValueKey('fleet.presets.noMatch'),
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          )
        else
          _presetChips(scripts),
      ],
    );
  }

  Widget _presetChips(List<QuickScript> scripts) {
    return SizedBox(
      height: 38,
      child: ListView(
        key: const ValueKey('fleet.presets'),
        scrollDirection: Axis.horizontal,
        children: [
          for (final script in scripts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: ActionChip(
                  key: ValueKey('fleet.preset.${script.id}'),
                  avatar: Text(
                    script.emoji,
                    style: const TextStyle(fontSize: 10, fontFamily: OmniFonts.mono),
                  ),
                  label: Text(script.name, style: const TextStyle(fontSize: 11)),
                  // Fills the field rather than running immediately: the confirmation dialog is
                  // where a broadcast gets approved, and a preset must not skip it.
                  onPressed: () => widget.onPick(script.command),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
