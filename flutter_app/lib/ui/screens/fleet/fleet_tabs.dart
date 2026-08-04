import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/fleet_view_model.dart';
import '../../view_model/scripts_view_model.dart';
import '../../widgets/omni_components.dart';

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
        itemBuilder: (context, index) => _HostCard(server: ordered[index]),
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.server});

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

    return OmniCard(
      key: ValueKey('fleet.host.${server.id}'),
      leftAccent: OmniColors.serverAccent(server.serverColor, server.name),
      child: Row(
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
            Text(
              '${server.healthScore}',
              key: ValueKey('fleet.host.${server.id}.score'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: OmniFonts.mono,
                color: scoreColor,
              ),
            )
          else
            // A score for an unreachable host is a stale number pretending to be current.
            const OmniTag(label: 'OFFLINE', color: OmniColors.textMuted),
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

    return Column(
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
              onPressed: vm.canRun ? () => _confirmAndRun(context, vm) : null,
              icon: vm.executing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(vm.executing ? 'Running…' : 'Run'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
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
    );
  }

  /// Shows exactly what will run where, then runs that exact list.
  ///
  /// The targets are snapshotted at tap time and passed through, so what the user approved is what
  /// executes — group membership and reachability are not re-resolved behind the dialog.
  Future<void> _confirmAndRun(BuildContext context, FleetViewModel vm) async {
    final targets = vm.resolvedTargets;
    final command = vm.commandText.trim();
    final danger = vm.dangerWarning;
    if (targets.isEmpty || command.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('fleet.run.dialog'),
        title: Text('Run on ${targets.length} host${targets.length == 1 ? '' : 's'}?'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '\$ $command',
                  style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                ),
                const SizedBox(height: 10),
                // Naming every host is the point: "5 hosts" is not something a user can check.
                for (final target in targets)
                  Text(
                    '• ${HostDisplay.instance.name(target)} '
                    '(${HostDisplay.instance.userAtHost(target)})',
                    style: const TextStyle(fontSize: 11),
                  ),
                if (danger != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    '⚠ $danger',
                    key: const ValueKey('fleet.run.dialog.danger'),
                    style: const TextStyle(fontSize: 12, color: OmniColors.red),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('fleet.run.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('fleet.run.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Run', style: TextStyle(color: danger != null ? OmniColors.red : null)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.runBroadcast(targets);
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ScriptsViewModel>().start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scripts = context.watch<ScriptsViewModel>().fleetPresetScripts;
    if (scripts.isEmpty) return const SizedBox.shrink();

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
