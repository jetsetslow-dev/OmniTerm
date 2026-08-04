import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/monitor_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Monitor sub-tabs, ported from `OverviewTab` / `ProcessesTab` / `ServicesTab` / `LogsTab` in
/// `ui/MonitorScreen.kt`.

/// CPU, memory, disks and uptime for the monitored host.
class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key, required this.vm, required this.server});

  final MonitorViewModel vm;
  final Server server;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  @override
  void initState() {
    super.initState();
    // The tab is built before its first frame, so the fetch is deferred rather than run during
    // build — notifying listeners mid-build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.vm.loadHostMetrics());
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final m = vm.metrics;
    final scheme = Theme.of(context).colorScheme;
    final accent = OmniColors.serverAccent(widget.server.serverColor, widget.server.name);

    return ListView(
      key: const ValueKey('monitor.overview'),
      children: [
        if (vm.metricsLoading) const LinearProgressIndicator(minHeight: 2),
        OmniCard(
          key: const ValueKey('monitor.overview.cpu'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CardLabel(text: 'CPU UTILISATION'),
                      Text(
                        'Load: ${m.load1} · ${m.load5} · ${m.load15}',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                      if (m.cpuTempC != null)
                        Text(
                          'Temp: ${m.cpuTempC!.round()}°C',
                          style: TextStyle(
                            fontSize: 12,
                            // A hot CPU is the one number here worth colouring — it predicts
                            // throttling and hardware failure, not just load.
                            color: m.cpuTempC! >= 80 ? OmniColors.red : scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    '${m.cpuPercent.round()}%',
                    key: const ValueKey('monitor.overview.cpuPercent'),
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      fontFamily: OmniFonts.mono,
                      color: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              GaugeBar(value: m.cpuPercent, color: accent, height: 6),
              if (m.perCoreCpu.isNotEmpty) ...[
                const SizedBox(height: 10),
                _CardLabel(text: 'PER-CORE (${m.perCoreCpu.length})'),
                const SizedBox(height: 4),
                for (final (i, v) in m.perCoreCpu.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 26,
                          child: Text(
                            'c$i',
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: OmniFonts.mono,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: GaugeBar(value: v, color: accent, height: 5),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${v.round()}%',
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontSize: 10, fontFamily: OmniFonts.mono),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        OmniCard(
          key: const ValueKey('monitor.overview.memory'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CardLabel(text: 'MEMORY OCCUPANCY'),
              const SizedBox(height: 6),
              Text(
                '${formatBytes(m.memUsedBytes)} of ${formatBytes(m.memTotalBytes)} '
                'occupied (${m.memPercent.round()}%)',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 10),
              GaugeBar(value: m.memPercent, color: OmniColors.amber, height: 7),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _DiskCard(metrics: m),
        const SizedBox(height: 12),
        OmniCard(
          key: const ValueKey('monitor.overview.stats'),
          child: Row(
            children: [
              Expanded(
                child: OmniStatBox(value: formatUptime(m.uptimeSeconds), label: 'Uptime'),
              ),
              Expanded(
                child: OmniStatBox(value: '${m.procCount}', label: 'Procs'),
              ),
              Expanded(
                child: OmniStatBox(value: '${m.tcpConnections}', label: 'TCP'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.metrics});

  final HostMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Every real mount when the host reported them, else the root summary — a host that only
    // answered the root probe should still show something.
    final mounts = metrics.disks.isNotEmpty
        ? metrics.disks
        : metrics.diskTotalBytes > 0
        ? [
            DiskUsage(
              mount: '/',
              filesystem: '',
              totalBytes: metrics.diskTotalBytes,
              usedBytes: metrics.diskUsedBytes,
            ),
          ]
        : const <DiskUsage>[];

    return OmniCard(
      key: const ValueKey('monitor.overview.disks'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _CardLabel(text: 'DISK MOUNTS'),
              if (metrics.diskReadPerSec > 0 || metrics.diskWritePerSec > 0)
                Text(
                  'R ${formatBytes(metrics.diskReadPerSec)}/s · '
                  'W ${formatBytes(metrics.diskWritePerSec)}/s',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: OmniFonts.mono,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (mounts.isEmpty)
            Text('—', style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant))
          else
            for (final disk in mounts)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            disk.mount,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono),
                          ),
                        ),
                        Text(
                          '${formatBytes(disk.usedBytes)} / ${formatBytes(disk.totalBytes)}',
                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    GaugeBar(
                      value: disk.percent,
                      // A nearly full filesystem is the failure this card exists to warn about.
                      color: disk.percent >= 90 ? OmniColors.red : OmniColors.cyan,
                      height: 5,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _CardLabel extends StatelessWidget {
  const _CardLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// The running process list, sortable by CPU or memory.
class ProcessesTab extends StatefulWidget {
  const ProcessesTab({super.key, required this.vm});

  final MonitorViewModel vm;

  @override
  State<ProcessesTab> createState() => _ProcessesTabState();
}

class _ProcessesTabState extends State<ProcessesTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.vm.loadProcesses());
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        if (vm.processesLoading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  ChoiceChip(
                    key: const ValueKey('monitor.processes.sortCpu'),
                    label: const Text('CPU'),
                    selected: vm.sortByCpu,
                    onSelected: (_) => vm.sortByCpu = true,
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    key: const ValueKey('monitor.processes.sortMem'),
                    label: const Text('MEM'),
                    selected: !vm.sortByCpu,
                    onSelected: (_) => vm.sortByCpu = false,
                  ),
                ],
              ),
              Text(
                '${vm.processes.length} Procs',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('monitor.processes.list'),
            itemCount: vm.processes.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final proc = vm.processes[index];
              final expanded = vm.expandedProcessPid == proc.pid;
              return OmniCard(
                key: ValueKey('monitor.process.${proc.pid}'),
                onTap: () => vm.toggleProcessExpanded(proc.pid),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            proc.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: OmniFonts.mono,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Text(
                          '${proc.cpu.toStringAsFixed(1)}%  ${proc.mem.toStringAsFixed(1)}%',
                          style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                        ),
                      ],
                    ),
                    Text(
                      'pid ${proc.pid} · ${proc.owner} · ${proc.state}',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                    if (expanded) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'vms ${proc.vms} · up ${proc.uptime}',
                              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                            ),
                          ),
                          TextButton(
                            key: ValueKey('monitor.process.${proc.pid}.kill'),
                            onPressed: () => _confirmKill(context, vm, proc),
                            child: const Text('Kill', style: TextStyle(color: OmniColors.red)),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _confirmKill(BuildContext context, MonitorViewModel vm, SimProcess proc) async {
    // Killing the wrong pid can take a host offline, and the list is sorted live — a row can move
    // under the finger between reading and tapping. So the dialog names what will be killed.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('monitor.kill.dialog'),
        title: Text('Kill ${proc.name}?'),
        content: Text('Sends SIGTERM to pid ${proc.pid} (${proc.owner}).'),
        actions: [
          TextButton(
            key: const ValueKey('monitor.kill.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('monitor.kill.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Kill', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.killProcess(proc.pid);
  }
}

/// systemd / OpenRC units, with start, stop and restart.
class ServicesTab extends StatefulWidget {
  const ServicesTab({super.key, required this.vm});

  final MonitorViewModel vm;

  @override
  State<ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<ServicesTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.vm.loadServices());
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final scheme = Theme.of(context).colorScheme;

    if (vm.servicesUnsupported && vm.services.isEmpty) {
      return Center(
        key: const ValueKey('monitor.services.unsupported'),
        child: Text(
          'This host runs neither systemd nor OpenRC, so its services cannot be listed.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      );
    }

    return Column(
      children: [
        if (vm.servicesLoading) const LinearProgressIndicator(minHeight: 2),
        if (vm.actionFeedback != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OmniCard(
              key: const ValueKey('monitor.services.feedback'),
              leftAccent: OmniColors.cyan,
              child: Row(
                children: [
                  Expanded(child: Text(vm.actionFeedback!, style: const TextStyle(fontSize: 12))),
                  IconButton(
                    key: const ValueKey('monitor.services.feedback.dismiss'),
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: vm.dismissActionFeedback,
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('monitor.services.list'),
            itemCount: vm.services.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final svc = vm.services[index];
              return OmniCard(
                key: ValueKey('monitor.service.${svc.name}'),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            svc.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: OmniFonts.mono,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          if (svc.desc.isNotEmpty)
                            Text(
                              svc.desc,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    OmniTag(label: svc.subState, color: _subStateColor(svc.subState)),
                    PopupMenuButton<String>(
                      key: ValueKey('monitor.service.${svc.name}.menu'),
                      onSelected: (action) => vm.runServiceAction(svc, action),
                      itemBuilder: (_) => [
                        for (final action in ['start', 'stop', 'restart', 'enable', 'disable'])
                          PopupMenuItem(value: action, child: Text(action)),
                      ],
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

  Color _subStateColor(String subState) => switch (subState) {
    'active' => OmniColors.green,
    'failed' => OmniColors.red,
    _ => OmniColors.textMuted,
  };
}

/// Host logs, with a level filter and a live tail.
class LogsTab extends StatefulWidget {
  const LogsTab({super.key, required this.vm});

  final MonitorViewModel vm;

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.vm.loadLogs());
  }

  @override
  void dispose() {
    // Leaving the tab must stop the 5-second tail; otherwise it keeps issuing SSH commands for a
    // pane nobody is looking at.
    widget.vm.logsLive = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final scheme = Theme.of(context).colorScheme;
    final lines = vm.filteredLogs;

    return Column(
      children: [
        if (vm.logsLoading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final filter in MonitorViewModel.logFilters)
                      ChoiceChip(
                        key: ValueKey('monitor.logs.filter.$filter'),
                        label: Text(filter, style: const TextStyle(fontSize: 11)),
                        selected: vm.logFilter == filter,
                        onSelected: (_) => vm.logFilter = filter,
                      ),
                  ],
                ),
              ),
              Text('LIVE', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              Switch(
                key: const ValueKey('monitor.logs.live'),
                value: vm.logsLive,
                onChanged: (v) => vm.logsLive = v,
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: Colors.black,
            padding: const EdgeInsets.all(8),
            child: lines.isEmpty && !vm.logsLoading
                ? Center(
                    key: ValueKey(
                      vm.logsUnsupported ? 'monitor.logs.unsupported' : 'monitor.logs.empty',
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      // Three situations all render as an empty black pane unless they are named:
                      // no log source at all, a source that returned nothing, and a filter that
                      // matched nothing. Only the first was ever explained.
                      child: Text(
                        vm.logsUnsupported
                            ? 'No readable log source on this host.'
                            : vm.logFilter == 'ALL'
                            ? 'No log entries on this host yet.'
                            : 'No ${vm.logFilter} entries. Choose ALL to see everything.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      key: const ValueKey('monitor.logs.list'),
                      itemCount: lines.length,
                      itemBuilder: (context, index) {
                        final entry = lines[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 72,
                                child: Text(
                                  '[${entry.time}]',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontFamily: OmniFonts.mono,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 48,
                                child: Text(
                                  entry.level,
                                  style: TextStyle(
                                    color: switch (entry.level) {
                                      'ERROR' => OmniColors.red,
                                      'WARN' => OmniColors.amber,
                                      _ => OmniColors.cyan,
                                    },
                                    fontFamily: OmniFonts.mono,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${entry.source}: ${entry.message}',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: OmniFonts.mono,
                                    fontSize: 12,
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
