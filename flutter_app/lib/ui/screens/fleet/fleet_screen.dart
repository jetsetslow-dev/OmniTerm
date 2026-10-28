import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_commands.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/fleet_view_model.dart';
import '../../view_model/scripts_view_model.dart';
import '../../widgets/health_breakdown_dialog.dart';
import '../../widgets/metric_line_chart.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/popup_scroll_behavior.dart';
import '../../widgets/streaming_command_dialog.dart';
import '../../widgets/script_editor_dialog.dart';

/// The Fleet screen, a faithful port of `FleetScreen` in `ui/FleetScreen.kt`: the summary bar,
/// a Dashboard / Broadcast / Logs tab row, and the selected tab inside 12dp of padding.
///
/// Like Kotlin, every tab works on the hosts that are online right now.
class FleetScreen extends StatelessWidget {
  const FleetScreen({super.key});

  static const _tabs = [FleetTab.dashboard, FleetTab.broadcast, FleetTab.logs];

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<FleetViewModel>();
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final tabs = OmniTabRow(
            key: const ValueKey('fleet.tabs'),
            labels: const ['Dashboard', 'Broadcast', 'Logs'],
            tabKeys: [for (final tab in _tabs) ValueKey('fleet.tab.${tab.name}')],
            selectedIndex: _tabs.indexOf(vm.activeTab),
            onSelected: (index) => vm.activeTab = _tabs[index],
          );
          final body = Padding(
            padding: const EdgeInsets.all(12),
            child: switch (vm.activeTab) {
              FleetTab.dashboard => _FleetDashboardView(vm: vm),
              FleetTab.broadcast => _FleetBroadcastView(vm: vm),
              FleetTab.logs => _FleetLogsView(vm: vm),
            },
          );
          // Landscape at large text leaves the tab body almost no height under the summary and
          // tabs. Kotlin clips there; here the screen scrolls with the body at a usable height.
          if (constraints.maxHeight < 360) {
            return SingleChildScrollView(
              child: Column(
                children: [
                  _FleetSummaryBar(vm: vm),
                  tabs,
                  SizedBox(height: 360, child: body),
                ],
              ),
            );
          }
          return Column(
            children: [
              _FleetSummaryBar(vm: vm),
              tabs,
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }
}

/// Kotlin's `FleetSummaryBar`, over every saved host (not only the online ones).
class _FleetSummaryBar extends StatelessWidget {
  const _FleetSummaryBar({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avg = vm.averageScoreOf(vm.servers);
    final critical = vm.criticalCountOf(vm.servers);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        key: const ValueKey('fleet.summary'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          children: [
            // Kotlin keeps these on one row. A Wrap renders identically at ordinary text sizes
            // and lets 200% text flow onto a second line instead of overflowing.
            Expanded(
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'FLEET',
                    style: composed(
                      TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFamily: OmniFonts.mono,
                        fontSize: 16,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  Text(
                    'Avg Score: ${avg < 0 ? '—' : avg}',
                    style: composed(
                      TextStyle(fontSize: 12, color: OmniColors.cyan, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    '${vm.onlineCount} / ${vm.totalCount} Online',
                    key: const ValueKey('fleet.summary.online'),
                    style: composed(
                      TextStyle(
                        fontSize: 12,
                        color: critical > 0 ? OmniColors.red : OmniColors.green,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Kotlin always has a poller; with none (or before its first sweep) there is no
            // cadence to describe.
            if (vm.nextRefreshAt != null)
              RefreshCountdown(
                key: const ValueKey('fleet.summary.countdown'),
                nextAt: vm.nextRefreshAt,
                interval: vm.refreshInterval,
                size: 16,
                color: OmniColors.green,
              ),
          ],
        ),
      ),
    );
  }
}

/// Kotlin's `FleetDashboardView`, fed the online hosts.
class _FleetDashboardView extends StatelessWidget {
  const _FleetDashboardView({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hosts = vm.onlineServers;
    final total = hosts.length;
    final critical = vm.criticalCountOf(hosts);
    final avg = vm.averageScoreOf(hosts);
    Widget stat(String value, String label, Color? color) => Expanded(
      child: OmniCard(
        child: OmniStatBox(value: value, label: label, color: color),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => ScrollConfiguration(
        behavior: const PopupScrollBehavior(popupsOnly: false),
        child: ListView(
          key: const ValueKey('fleet.dashboard.list'),
          children: [
            Row(
              children: [
                stat('$total', 'Hosts', null),
                const SizedBox(width: 8),
                stat('$total', 'Online', OmniColors.green),
                const SizedBox(width: 8),
                stat(
                  '$critical',
                  'Critical',
                  critical > 0 ? OmniColors.red : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                stat(avg < 0 ? '—' : '$avg', 'Avg Score', OmniColors.cyan),
              ],
            ),
            if (hosts.isEmpty)
              SizedBox(
                height: (constraints.maxHeight - 90).clamp(0.0, double.infinity),
                child: Center(
                  key: const ValueKey('fleet.dashboard.empty'),
                  child: Text(
                    'No online hosts available. Fleet details appear when hosts come back online.',
                    textAlign: TextAlign.center,
                    style: composed(TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ),
              ),
            for (final server in hosts) ...[
              const SizedBox(height: 12),
              _FleetHostCard(vm: vm, server: server),
            ],
          ],
        ),
      ),
    );
  }
}

class _FleetHostCard extends StatelessWidget {
  const _FleetHostCard({required this.vm, required this.server});

  final FleetViewModel vm;
  final Server server;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = HostDisplay.instance;
    final accent = OmniColors.serverAccent(server.serverColor, server.name);
    final online = server.status == 'online';
    final upHours = vm.uptimeSecondsFor(server.id) ~/ 3600;
    final haveData = online && upHours > 0;
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
                    Row(
                      children: [
                        StatusDot(online: online, color: accent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            display.name(server),
                            overflow: TextOverflow.ellipsis,
                            style: composed(
                              TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                fontFamily: OmniFonts.mono,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '${display.userAtHost(server)}:${server.port}',
                      overflow: TextOverflow.ellipsis,
                      style: composed(TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                  ],
                ),
              ),
              InkWell(
                key: ValueKey('fleet.host.${server.id}.score.open'),
                onTap: () => showHealthBreakdown(
                  context,
                  name: display.name(server),
                  breakdown: vm.healthBreakdownFor(server),
                ),
                child: ScoreRing(
                  key: ValueKey('fleet.host.${server.id}.score'),
                  score: vm.currentHealthScore(server),
                  size: 42,
                ),
              ),
            ],
          ),
          if (online) ...[
            const SizedBox(height: 10),
            MetricLineChart(
              key: ValueKey('fleet.host.${server.id}.chart'),
              points: vm.cpuHistoryFor(server.id),
              timestamps: vm.historyTimestampsFor(server.id),
              color: accent,
              label: 'CPU',
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final check in QuickCheck.values)
                    OmniButton(
                      key: ValueKey('fleet.host.${server.id}.${check.label.toLowerCase()}'),
                      label: check.label,
                      color: accent,
                      small: true,
                      onPressed: () async {
                        final command = await vm.quickCheckFor(server, check);
                        if (!context.mounted) return;
                        await showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => StreamingCommandDialog(
                            title: '${check.label} · ${display.name(server)}',
                            command: command,
                            run: (onChunk, cancellation) => vm.runHostDiagnostic(
                              server,
                              command,
                              onChunk: onChunk,
                              cancellation: cancellation,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Derived from the host's reported kernel uptime: the boot can be placed inside the
          // window; earlier than that is genuinely unknown.
          Text(
            haveData
                ? (upHours >= 24 ? '24H UPTIME · up >24h' : '24H UPTIME · booted ${upHours}h ago')
                : '24H UPTIME · no data',
            key: ValueKey('fleet.host.${server.id}.uptime24'),
            style: composed(TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                for (var i = 0; i < 24; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(1),
                        color: switch (23 - i) {
                          _ when !haveData => Colors.grey.withValues(alpha: 0.25),
                          final hoursAgo when upHours > hoursAgo => const Color(
                            0xFF10B981,
                          ).withValues(alpha: 0.85),
                          final hoursAgo when upHours == hoursAgo => OmniColors.amber.withValues(
                            alpha: 0.8,
                          ),
                          _ => Colors.grey.withValues(alpha: 0.25),
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kotlin's `FleetBroadcastView`.
class _FleetBroadcastView extends StatefulWidget {
  const _FleetBroadcastView({required this.vm});

  final FleetViewModel vm;

  @override
  State<_FleetBroadcastView> createState() => _FleetBroadcastViewState();
}

class _FleetBroadcastViewState extends State<_FleetBroadcastView> {
  late final TextEditingController _command = TextEditingController(text: widget.vm.commandText);
  bool _controlsExpanded = true;
  int _seenResults = 0;

  /// Collapsed output cards by server id. Absent means expanded, so fresh results start open.
  final Map<int, bool> _collapsed = {};
  bool _wasExecuting = false;

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  void _syncFromModel() {
    final vm = widget.vm;
    // Kotlin collapses the controls once results arrive so the outputs get the room.
    if (vm.results.isNotEmpty && vm.results.length != _seenResults) _controlsExpanded = false;
    _seenResults = vm.results.length;
    // A new run, or cleared outputs, starts every card expanded again.
    if ((vm.executing && !_wasExecuting) || vm.results.isEmpty) _collapsed.clear();
    _wasExecuting = vm.executing;
    if (_command.text != vm.commandText) _command.text = vm.commandText;
  }

  Future<void> _confirmAndRun() async {
    final vm = widget.vm;
    final cmd = vm.commandText.trim();
    if (cmd.isEmpty || vm.executing) return;
    final targets = vm.resolvedTargets;
    if (targets.isEmpty) return;
    if (!vm.canBroadcast) {
      // Kotlin always has SSH; a build without it must say so rather than drop the tap.
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: const Text('Broadcasting is unavailable in this build.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    final danger = vm.dangerWarning;
    final display = HostDisplay.instance;
    final message = StringBuffer('\$ $cmd\n\n');
    message.write(targets.map((t) => '• ${display.name(t)} (${display.userAtHost(t)})').join('\n'));
    if (danger != null) message.write('\n\n⚠ $danger');
    final confirmed = await showOmniConfirm(
      context,
      title: 'Run on ${targets.length} host${targets.length == 1 ? '' : 's'}?',
      message: message.toString(),
      confirmLabel: 'Run',
      destructive: danger != null,
      keyPrefix: 'run',
    );
    if (confirmed) await vm.runBroadcast(targets);
  }

  Future<void> _pickPreset() async {
    final scripts = context.read<ScriptsViewModel>();
    await scripts.start();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _PresetPickerDialog(scripts: scripts),
    );
    if (picked != null) widget.vm.commandText = picked;
  }

  Future<void> _confirmClearOutputs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('fleet.clearOutputs.dialog'),
        title: const Text('Clear broadcast output?'),
        content: const Text('This clears the visible Fleet broadcast output history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('fleet.clearOutputs.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.vm.clearResults();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    _syncFromModel();
    final scheme = Theme.of(context).colorScheme;
    final count = vm.resolvedTargets.length;
    final meta = composed(TextStyle(fontSize: 11, color: scheme.onSurfaceVariant));
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_controlsExpanded) ...[
          _BroadcastTargetPicker(vm: vm),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('fleet.command'),
            controller: _command,
            onChanged: (value) => vm.commandText = value,
            style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 14),
            decoration:
                omniInputDecoration(
                  context,
                  labelText: 'Command',
                  hintText: 'Enter bash command script here...',
                ).copyWith(
                  prefixText: '\$ ',
                  prefixStyle: TextStyle(
                    fontFamily: OmniFonts.mono,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
          ),
          const SizedBox(height: 8),
          Text('Command presets', style: composed(TextStyle(fontWeight: FontWeight.bold))),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('fleet.presets.open'),
                  onPressed: _pickPreset,
                  icon: const Icon(Icons.search, size: 16),
                  label: const Text('Presets'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('fleet.saveCommand'),
                  onPressed: vm.commandText.trim().isEmpty
                      ? null
                      : () => showScriptEditorDialog(
                          context,
                          context.read<ScriptsViewModel>(),
                          title: 'Save script',
                          initialCommand: vm.commandText,
                          initialCategory: 'Fleet',
                          defaultAvailableForQuick: false,
                          defaultAvailableForFleet: true,
                        ),
                  icon: const Icon(Icons.save, size: 16),
                  label: const Text('Save command'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          OmniButton(
            key: const ValueKey('fleet.run'),
            label: vm.executing ? 'STOP BROADCAST' : 'RUN ON $count HOSTS',
            color: vm.executing ? OmniColors.red : OmniColors.cyan,
            expand: true,
            onPressed: vm.executing ? vm.cancelBroadcast : _confirmAndRun,
          ),
        ] else
          OmniButton(
            key: const ValueKey('fleet.run'),
            label: vm.executing ? 'STOP' : 'RUN $count',
            color: vm.executing ? OmniColors.red : OmniColors.cyan,
            small: true,
            expand: true,
            onPressed: vm.executing ? vm.cancelBroadcast : _confirmAndRun,
          ),
        if (vm.startWarning != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              vm.startWarning!,
              key: const ValueKey('fleet.broadcast.startWarning'),
              style: composed(TextStyle(color: OmniColors.amber, fontSize: 12)),
            ),
          ),
      ],
    );
    final outputsHeader = Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Execution outputs', style: meta.copyWith(fontWeight: FontWeight.bold)),
          if (vm.results.isNotEmpty && !vm.executing)
            InkWell(
              key: const ValueKey('fleet.clearResults'),
              onTap: _confirmClearOutputs,
              child: Text(
                'Clear Outputs',
                style: composed(TextStyle(fontSize: 11, color: Colors.red)),
              ),
            ),
        ],
      ),
    );
    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Broadcast controls', style: meta.copyWith(fontWeight: FontWeight.bold)),
              Text(
                '$count target(s) · '
                '${vm.commandText.trim().isEmpty ? 'no command' : vm.commandText}',
                key: const ValueKey('fleet.targetCount'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta,
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('fleet.controls.toggle'),
          tooltip: _controlsExpanded ? 'Collapse controls' : 'Expand controls',
          onPressed: () => setState(() => _controlsExpanded = !_controlsExpanded),
          icon: Icon(_controlsExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right),
        ),
      ],
    );
    final outputs = ScrollConfiguration(
      behavior: const PopupScrollBehavior(popupsOnly: false),
      child: ListView.separated(
        key: const ValueKey('fleet.results'),
        itemCount: vm.results.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final result = vm.results[index];
          return _BroadcastOutputCard(
            result: result,
            expanded: _collapsed[result.serverId] != true,
            onToggle: () => setState(() {
              _collapsed[result.serverId] = _collapsed[result.serverId] != true;
            }),
          );
        },
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Kotlin keeps the controls fixed above an output list that scrolls on its own. Below a
        // usable height (landscape at large text) both cannot fit, so the tab becomes one
        // scrolling page with a fixed-height output pane instead of overflowing.
        if (constraints.maxHeight < 320) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                controls,
                outputsHeader,
                SizedBox(height: 160, child: outputs),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            // The headers grow with the text scale (Compose line heights), so the room kept for
            // them and the outputs scales too; a fixed "height - 140" overflowed at 2×.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    (constraints.maxHeight -
                            140 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0))
                        .clamp(0.0, double.infinity),
              ),
              child: SingleChildScrollView(child: controls),
            ),
            outputsHeader,
            Expanded(child: outputs),
          ],
        );
      },
    );
  }
}

/// Kotlin's `BroadcastTargetPicker`.
class _BroadcastTargetPicker extends StatelessWidget {
  const _BroadcastTargetPicker({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final servers = vm.onlineServers;
    final groups = vm.groups;
    final serversMode = vm.targetMode == FleetTargetMode.servers;
    const small = TextStyle(fontSize: 11);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Broadcast Targets',
                  style: composed(
                    TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              FilterChip(
                key: const ValueKey('fleet.targetMode.servers'),
                label: const Text('Servers', style: small),
                selected: serversMode,
                onSelected: (_) => vm.targetMode = FleetTargetMode.servers,
              ),
              const SizedBox(width: 8),
              FilterChip(
                key: const ValueKey('fleet.targetMode.groups'),
                label: const Text('Groups', style: small),
                selected: !serversMode,
                onSelected: (_) => vm.targetMode = FleetTargetMode.groups,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                InkWell(
                  key: const ValueKey('fleet.targets.all'),
                  onTap: vm.selectAllTargets,
                  child: Text(
                    serversMode ? 'All Online' : 'All Groups',
                    style: composed(
                      TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: scheme.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                InkWell(
                  key: const ValueKey('fleet.targets.clear'),
                  onTap: vm.clearTargets,
                  child: Text(
                    'Clear',
                    style: composed(
                      TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (serversMode)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: HostPickerField(
                fieldKey: const ValueKey('fleet.targets.hosts'),
                label: 'Target hosts',
                servers: servers,
                selectedIds: vm.targetServerIds,
                onToggle: vm.toggleTargetServer,
                isSelectable: (s) => s.status == 'online',
                onSelectAll: vm.selectAllTargets,
                onClear: vm.clearTargets,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final group in groups)
                    FilterChip(
                      key: ValueKey('fleet.targetGroup.$group'),
                      elevation: 1,
                      label: Text(
                        '$group (${servers.where((s) => s.groupName == group).length})',
                        style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                      ),
                      selected: vm.targetGroups.contains(group),
                      onSelected: (_) => vm.toggleTargetGroup(group),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BroadcastOutputCard extends StatefulWidget {
  const _BroadcastOutputCard({
    required this.result,
    required this.expanded,
    required this.onToggle,
  });

  final BroadcastResult result;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_BroadcastOutputCard> createState() => _BroadcastOutputCardState();
}

class _BroadcastOutputCardState extends State<_BroadcastOutputCard> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final scheme = Theme.of(context).colorScheme;
    final (accent, status) = switch (result.status) {
      BroadcastStatus.pending || BroadcastStatus.running => (OmniColors.cyan, 'streaming'),
      BroadcastStatus.success => (OmniColors.green, 'complete'),
      BroadcastStatus.failure || BroadcastStatus.cancelled => (OmniColors.red, 'failed'),
    };
    final running = !result.isDone;
    final output = result.output.toString();
    final text = [
      if (result.note != null) result.note!,
      if (output.trim().isEmpty) running ? 'Waiting for output...' : 'Done (no output)' else output,
    ].join('\n');
    // Follow the stream, as Kotlin scrolls to the bottom whenever the output grows.
    if (widget.expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    return OmniCard(
      key: ValueKey('fleet.result.${result.serverId}'),
      leftAccent: OmniColors.hostColor(result.serverName),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('fleet.result.${result.serverId}.toggle'),
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(
                    widget.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                    color: scheme.primary,
                    semanticLabel: widget.expanded ? 'Collapse output' : 'Expand output',
                  ),
                  Expanded(
                    child: Text(
                      result.serverName,
                      overflow: TextOverflow.ellipsis,
                      style: composed(
                        TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          fontFamily: OmniFonts.mono,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                  if (running) ...[
                    SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    status,
                    style: composed(
                      TextStyle(fontSize: 10, color: accent, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.expanded)
            Container(
              constraints: const BoxConstraints(minHeight: 72, maxHeight: 260),
              color: Colors.black,
              child: ScrollConfiguration(
                behavior: const PopupScrollBehavior(popupsOnly: false),
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  child: SelectionArea(
                    child: Text(
                      text,
                      style: composed(
                        TextStyle(fontFamily: OmniFonts.mono, fontSize: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Kotlin's preset `AlertDialog`: searchable fleet scripts, sorted by order then name.
class _PresetPickerDialog extends StatefulWidget {
  const _PresetPickerDialog({required this.scripts});

  final ScriptsViewModel scripts;

  @override
  State<_PresetPickerDialog> createState() => _PresetPickerDialogState();
}

class _PresetPickerDialogState extends State<_PresetPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final presets = [...widget.scripts.fleetPresetScripts]
      ..sort((a, b) {
        final order = a.sortOrder.compareTo(b.sortOrder);
        return order != 0 ? order : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? presets
        : presets
              .where((p) => p.name.toLowerCase().contains(q) || p.command.toLowerCase().contains(q))
              .toList();
    return AlertDialog(
      key: const ValueKey('fleet.presets.dialog'),
      title: const Text('Choose fleet script'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('fleet.presets.search'),
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                labelText: 'Search presets',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            if (filtered.isEmpty)
              Text(
                presets.isEmpty ? 'No fleet presets saved yet.' : 'No presets match your search.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              )
            else
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final preset = filtered[index];
                      return ListTile(
                        key: ValueKey('fleet.preset.${preset.id}'),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        title: Text(
                          '${preset.emoji} ${preset.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          preset.command,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                        ),
                        onTap: () => Navigator.of(context).pop(preset.command),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

/// Kotlin's `FleetLogsView`.
class _FleetLogsView extends StatelessWidget {
  const _FleetLogsView({required this.vm});

  final FleetViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final servers = vm.onlineServers;
    final logs = vm.logs;
    return ShortViewportScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Select hosts then tap Fetch Logs:',
            style: composed(TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 8),
          HostPickerField(
            fieldKey: const ValueKey('fleet.logs.hosts'),
            label: 'Log hosts',
            servers: servers,
            selectedIds: vm.logServerIds,
            onToggle: vm.toggleLogServer,
            onSelectAll: vm.selectAllLogServers,
            onClear: vm.clearLogServers,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OmniButton(
                key: const ValueKey('fleet.logs.reload'),
                label: vm.logsLoading ? 'Loading…' : 'Fetch Logs',
                onPressed: vm.logsLoading ? null : vm.loadLogs,
              ),
              if (logs.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  '${logs.length} entries',
                  style: composed(TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: logs.isEmpty && !vm.logsLoading
                ? Center(
                    key: const ValueKey('fleet.logs.empty'),
                    child: Text(
                      'No logs. Select hosts and tap Fetch Logs.',
                      style: composed(TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  )
                : ScrollConfiguration(
                    behavior: const PopupScrollBehavior(popupsOnly: false),
                    child: ListView.separated(
                      key: const ValueKey('fleet.logs.list'),
                      itemCount: logs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final entry = logs[index];
                        final levelColor = switch (entry.level) {
                          'ERROR' => OmniColors.red,
                          'WARN' => OmniColors.amber,
                          _ => scheme.onSurface,
                        };
                        return OmniCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    entry.serverName,
                                    style: composed(
                                      TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: OmniColors.cyan,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    entry.timestamp,
                                    style: composed(
                                      TextStyle(
                                        fontSize: 10,
                                        fontFamily: OmniFonts.mono,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                entry.message,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: composed(
                                  TextStyle(
                                    fontSize: 11,
                                    fontFamily: OmniFonts.mono,
                                    color: levelColor,
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
        ],
      ),
    );
  }
}
