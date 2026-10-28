import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_commands.dart';
import '../../../data/remote_models.dart';
import '../../../data/remote_parsers.dart';
import '../../../domain/measurement_units.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'package:provider/provider.dart';
import '../../view_model/app_lock_controller.dart';
import '../../widgets/sudo_auth_dialog.dart';
import '../../view_model/monitor_view_model.dart';
import '../../widgets/command_output_card.dart';
import '../../widgets/metric_line_chart.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';

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
    final server = widget.server;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final accent = OmniColors.serverAccent(server.serverColor, server.name);
    final available = vm.hasCurrentMetrics;
    final online = server.status == 'online';

    // Kotlin's OverflowLazyColumn(spacedBy 12): CPU and memory always render, with "unavailable"
    // in place of figures, under a waiting card that offers Retry.
    final cards = <Widget>[
      if (!available)
        OmniCard(
          key: const ValueKey('monitor.overview.waiting'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (vm.metricsLoading) const LinearProgressIndicator(),
              Text(
                vm.metricsError ?? 'Waiting for verified CPU, memory and disk metrics.',
                style: composeBody(),
              ),
              TextButton(
                key: const ValueKey('monitor.overview.retry'),
                onPressed: vm.metricsLoading ? null : vm.loadHostMetrics,
                child: const Text('Retry metrics'),
              ),
            ],
          ),
        ),
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
                    const _CardLabel(text: 'CPU UTILISATION'),
                    Text(
                      available
                          ? 'Load: ${m.load1} · ${m.load5} · ${m.load15}'
                          : 'Current load unavailable',
                      style: composeBody(fontSize: 12, color: muted),
                    ),
                    if (m.cpuTempC != null)
                      Text(
                        'Temp: ${formatTemperature(m.cpuTempC!, vm.measurementSystem)}',
                        style: composeBody(
                          fontSize: 12,
                          color: m.cpuTempC! >= 80 ? OmniColors.red : muted,
                        ),
                      ),
                  ],
                ),
                Text(
                  available ? '${m.cpuPercent.round()}%' : '—',
                  key: const ValueKey('monitor.overview.cpuPercent'),
                  style: composeBody(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    fontFamily: OmniFonts.mono,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            MetricLineChart(
              key: const ValueKey('monitor.overview.cpuChart'),
              points: vm.cpuHistory,
              timestamps: vm.historyTimestamps,
              color: accent,
              label: 'CPU utilisation',
            ),
            if (m.perCoreCpu.isNotEmpty) ...[
              const SizedBox(height: 10),
              _CardLabel(text: 'PER-CORE (${m.perCoreCpu.length})', fontSize: 10),
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
                          style: composeBody(
                            fontSize: 10,
                            fontFamily: OmniFonts.mono,
                            color: muted,
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
                          style: composeBody(fontSize: 10, fontFamily: OmniFonts.mono),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
      OmniCard(
        key: const ValueKey('monitor.overview.memory'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardLabel(text: 'MEMORY OCCUPANCY'),
            const SizedBox(height: 6),
            Text(
              available
                  ? '${humanBytes(m.memUsedBytes)} of ${humanBytes(m.memTotalBytes)} '
                        'occupied (${m.memPercent.round()}%)'
                  : 'Current memory unavailable',
              style: composeBody(fontSize: 14),
            ),
            const SizedBox(height: 10),
            GaugeBar(value: m.memPercent, color: OmniColors.amber, height: 7),
            const SizedBox(height: 12),
            MetricLineChart(
              key: const ValueKey('monitor.overview.ramChart'),
              points: vm.ramHistory,
              timestamps: vm.historyTimestamps,
              color: OmniColors.amber,
              label: 'RAM utilisation',
            ),
          ],
        ),
      ),
      if (available) ...[
        _DiskCard(metrics: m),
        OmniCard(
          key: const ValueKey('monitor.overview.network'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const _CardLabel(text: 'Network'),
                  Text(
                    'TCP: ${m.tcpConnections}',
                    style: composeBody(fontSize: 11, fontFamily: OmniFonts.mono, color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '↓ ${humanBytes(m.netRxPerSec)}/s   ↑ ${humanBytes(m.netTxPerSec)}/s',
                style: composeBody(fontSize: 14, fontFamily: OmniFonts.mono, color: accent),
              ),
              if (m.netInterfaces.isEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Per-interface rates appear after the next refresh.',
                  style: composeBody(fontSize: 10, color: muted),
                ),
              ] else
                for (final iface in m.netInterfaces) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        iface.name,
                        style: composeBody(
                          fontSize: 12,
                          fontFamily: OmniFonts.mono,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '↓${humanBytes(iface.rxPerSec)}/s ↑${humanBytes(iface.txPerSec)}/s',
                        style: composeBody(fontSize: 11, fontFamily: OmniFonts.mono, color: muted),
                      ),
                    ],
                  ),
                  Text(
                    'total ↓${humanBytes(iface.rxBytes)} ↑${humanBytes(iface.txBytes)}',
                    style: composeBody(fontSize: 10, color: muted),
                  ),
                ],
            ],
          ),
        ),
        OmniCard(
          key: const ValueKey('monitor.overview.system'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'System', padding: EdgeInsets.zero),
              if (m.os.trim().isNotEmpty) _StatRow(label: 'OS', value: m.os),
              _StatRow(label: 'Uptime', value: formatUptime(m.uptimeSeconds)),
              _StatRow(label: 'Processes', value: m.procCount > 0 ? '${m.procCount}' : '—'),
              _StatRow(label: 'Latency', value: online ? '${server.lastLatency} ms' : '—'),
              _StatRow(label: 'Status', value: online ? 'Online' : 'Offline'),
            ],
          ),
        ),
      ],
      _RetainedHistoryCard(vm: vm, accent: accent),
    ];

    return ListView.separated(
      key: const ValueKey('monitor.overview'),
      itemCount: cards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) => cards[i],
    );
  }
}

/// Kotlin's `StatRow`: a 14sp label and a bold monospace value on one line.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: composeBody(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: composeBody(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: OmniFonts.mono,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The retained telemetry card, ported from the `7-DAY HISTORY` block in `ui/MonitorScreen.kt:768`.
///
/// Distinct from the charts above it, which are the poller's in-memory samples: minutes of detail
/// that vanish on restart. This reads the rows the telemetry poller has been writing all along —
/// data the app already stored, already pruned on a schedule, and until now never showed.
///
/// Absent rather than empty until there are at least two points, because a chart is a claim about
/// change over time and one reading cannot support it.
class _RetainedHistoryCard extends StatefulWidget {
  const _RetainedHistoryCard({required this.vm, required this.accent});

  final MonitorViewModel vm;
  final Color accent;

  @override
  State<_RetainedHistoryCard> createState() => _RetainedHistoryCardState();
}

class _RetainedHistoryCardState extends State<_RetainedHistoryCard> {
  @override
  void initState() {
    super.initState();
    // Deferred: the query notifies listeners, and doing that during build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.vm.loadHourlySeries());
  }

  @override
  void didUpdateWidget(_RetainedHistoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Picks up a change of monitored host; the load itself is a no-op when the host is unchanged.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.vm.loadHourlySeries());
  }

  @override
  Widget build(BuildContext context) {
    final series = widget.vm.hourlySeries;
    if (series == null || series.cpu.length < 2) return const SizedBox.shrink();

    final system = widget.vm.measurementSystem;
    final temperatures = [
      for (final point in series.temperature) celsiusToDisplay(point.value, system),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OmniCard(
        key: const ValueKey('monitor.overview.retainedHistory'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardLabel(text: '7-DAY HISTORY'),
            const SizedBox(height: 8),
            MetricLineChart(
              key: const ValueKey('monitor.overview.hourlyCpu'),
              points: [for (final point in series.cpu) point.value],
              timestamps: [for (final point in series.cpu) point.timestamp],
              color: widget.accent,
              label: 'CPU (hourly avg)',
            ),
            const SizedBox(height: 12),
            MetricLineChart(
              key: const ValueKey('monitor.overview.hourlyRam'),
              points: [for (final point in series.ram) point.value],
              timestamps: [for (final point in series.ram) point.timestamp],
              color: OmniColors.amber,
              label: 'RAM (hourly avg)',
            ),
            // Hidden outright when no sensor reported, rather than drawn flat at zero: a host with
            // no thermal sensor is not a host running at 0°.
            if (temperatures.isNotEmpty) ...[
              const SizedBox(height: 12),
              MetricLineChart(
                key: const ValueKey('monitor.overview.hourlyTemp'),
                points: temperatures,
                timestamps: [for (final point in series.temperature) point.timestamp],
                color: OmniColors.red,
                label: 'Temperature (hourly avg)',
                unit: temperatureUnit(system),
                // The axis must cover a real reading that exceeds the nominal ceiling, or a
                // thermally runaway host would be drawn clipped at the top and look merely warm.
                maxY: [
                  celsiusToDisplay(100, system),
                  ...temperatures,
                ].reduce((a, b) => a > b ? a : b),
              ),
            ],
          ],
        ),
      ),
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
    // Why the per-mount listing is missing, when the host was able to tell us.
    final disksUnavailable = metrics.unavailable['DISKS'] ?? metrics.unavailable['DISK'];
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
          // A bare em dash reads as "this host has no disks", which is wrong and unhelpful when the
          // truth is that the probe was blocked. If the host told us why, say so instead.
          if (mounts.isEmpty && disksUnavailable != null)
            Text(disksUnavailable, style: const TextStyle(fontSize: 11, color: OmniColors.amber))
          else if (mounts.isEmpty)
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

/// Runs a service action, re-authenticating first when it would use a stored sudo password.
///
/// Starting or stopping a unit is privileged, and on a host with a saved sudo password it needs no
/// credential from the user at all — so anyone holding the unlocked phone can stop `sshd`. Kotlin
/// puts the same gate on this and on reboot (`withSudoAuth`, `ui/AppViewModel.kt:2521`).
Future<void> _runServiceAction(
  BuildContext context,
  MonitorViewModel vm,
  SimService service,
  String action,
) async {
  final server = vm.monitoredServer;
  final lock = context.read<AppLockController>();
  // launchd and Windows services are managed without sudo, so the password is neither sent nor gated.
  if (server != null &&
      serviceActionUsesSudo(vm.knownOs) &&
      lock.requiresSudoAuth(server.sudoPassword)) {
    if (!await requestSudoAuth(context, lock)) return;
  }
  await vm.runServiceAction(service, action);
}

class _CardLabel extends StatelessWidget {
  const _CardLabel({required this.text, this.fontSize = 11});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: composeBody(
      fontSize: fontSize,
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _ProcessesToolbar extends StatelessWidget {
  const _ProcessesToolbar({required this.vm});
  final MonitorViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          // Only while refreshing rows that are already on screen. A 2px bar above an *empty* list is
          // indistinguishable from a host with nothing running, which is the wrong thing to tell
          // someone waiting for a first load — Kotlin splits the two the same way
          // (`ui/MonitorScreen.kt`, `processesLoading && isEmpty`).
          if (vm.processesLoading && vm.processes.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Four chips do not fit a phone's width beside the count, so they scroll rather
                // than push it off screen.
                Flexible(
                  flex: 3,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (i, (sort, key, label)) in [
                          (ProcessSort.cpu, 'sortCpu', '↓ CPU'),
                          (ProcessSort.mem, 'sortMem', '↓ MEM'),
                          if (vm.processDiskReported) (ProcessSort.disk, 'sortDisk', '↓ DISK'),
                          if (vm.processGpuReported) (ProcessSort.gpu, 'sortGpu', '↓ GPU'),
                        ].indexed) ...[
                          if (i > 0) const SizedBox(width: 8),
                          ChoiceChip(
                            key: ValueKey('monitor.processes.$key'),
                            label: Text(label),
                            selected: vm.processSort == sort,
                            onSelected: (_) => vm.sortProcessesBy(sort),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Flexible(
                  child: vm.processesLoading && vm.processes.isEmpty
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              key: ValueKey('monitor.processes.firstLoadProgress'),
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Reading…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        )
                      : Text(
                          '${vm.processes.length} Procs',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
    final windows = normaliseOs(vm.knownOs) == 'Windows';

    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        key: const ValueKey('monitor.processes.scroll'),
        slivers: [
          // Keep sorting visible with enough space. In a tiny viewport the toolbar
          // scrolls with its content; first-load progress is visible in either layout.
          if (constraints.maxHeight >=
              96 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, double.infinity))
            PinnedHeaderSliver(child: _ProcessesToolbar(vm: vm))
          else
            SliverToBoxAdapter(child: _ProcessesToolbar(vm: vm)),
          if (vm.processes.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: vm.processesLoading
                    ? const Column(
                        key: ValueKey('monitor.processes.loading'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(height: 10),
                          Text('Reading the process list…', style: TextStyle(fontSize: 12)),
                        ],
                      )
                    : Text(
                        // Every host runs *something*, so an empty list after a successful read is
                        // the parse failing, not the host being idle. Saying "no processes" would be
                        // a confident false statement about the machine.
                        'The process list came back empty — this host may not support the '
                        'command, or its output was not understood.',
                        key: const ValueKey('monitor.processes.empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
              ),
            )
          else
            SliverList.separated(
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        proc.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: OmniFonts.mono,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    OmniTag(
                                      label: proc.state,
                                      color: proc.state == 'R' ? OmniColors.green : OmniColors.cyan,
                                    ),
                                  ],
                                ),
                                Text(
                                  [
                                    'PID ${proc.pid} · ${proc.owner}',
                                    if (proc.uptime.trim().isNotEmpty) 'up ${proc.uptime}',
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          _ProcessStat(value: '${proc.cpu}%', label: 'CPU', busy: proc.cpu > 20),
                          const SizedBox(width: 12),
                          _ProcessStat(value: '${proc.mem}%', label: 'MEM', busy: proc.mem > 20),
                          if (vm.processDiskReported) ...[
                            const SizedBox(width: 12),
                            _ProcessStat(
                              value: switch (proc.disk) {
                                final disk? => '${humanBytes(disk.totalBytesPerSecond)}/s',
                                null => '—',
                              },
                              label: 'DISK',
                              busy: (proc.disk?.totalBytesPerSecond ?? 0) > 10 * 1024 * 1024,
                            ),
                          ],
                          if (vm.processGpuReported) ...[
                            const SizedBox(width: 12),
                            _ProcessStat(
                              value: switch (proc.gpu) {
                                final gpu? => '${gpu.round()}%',
                                null => '—',
                              },
                              label: 'GPU',
                              busy: (proc.gpu ?? 0) > 20,
                            ),
                          ],
                        ],
                      ),
                      if (expanded) ...[
                        Divider(height: 17, thickness: 1, color: scheme.outlineVariant),
                        Text(
                          'Virtual Memory Size (VMS): ${proc.vms}',
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        if (proc.disk case final disk?)
                          Text(
                            'Disk: read ${humanBytes(disk.readBytesPerSecond)}/s · '
                            'write ${humanBytes(disk.writeBytesPerSecond)}/s',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            // SIGTERM is exactly the signal a wedged process ignores, so an app
                            // that only sends it cannot end the one case you reach for it.
                            for (final (i, kill) in _killWordings(windows: windows).indexed) ...[
                              if (i > 0) const SizedBox(width: 10),
                              OmniButton(
                                key: ValueKey('monitor.process.${proc.pid}.${kill.key}'),
                                label: kill.button,
                                color: kill.color,
                                small: true,
                                onPressed: () => _confirmKill(context, vm, proc, kill),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  /// Confirms, then ends [proc] the way [kill] describes.
  ///
  /// The gentle and the forced way are separate actions with separate prompts, as in Kotlin: the two
  /// differ in whether the process gets to save anything, which is a choice to make before
  /// confirming, not while confirming.
  Future<void> _confirmKill(
    BuildContext context,
    MonitorViewModel vm,
    SimProcess proc,
    _KillWording kill,
  ) async {
    // Killing the wrong pid can take a host offline, and the list is sorted live — a row can move
    // under the finger between reading and tapping. So the dialog names what will be killed.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('monitor.kill.dialog'),
        title: Text(kill.title),
        content: Text(kill.message(proc)),
        actions: [
          TextButton(
            key: const ValueKey('monitor.kill.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('monitor.kill.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(kill.confirm, style: TextStyle(color: kill.color)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await vm.killProcess(proc.pid, signal: kill.signal);
    }
  }
}

/// One way of ending a process, in the words its OS uses.
/// One figure in a process row: the value over its label, red while the process is busy on it.
class _ProcessStat extends StatelessWidget {
  const _ProcessStat({required this.value, required this.label, required this.busy});

  final String value;
  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: busy ? const Color(0xFFFF0000) : scheme.onSurface,
          ),
        ),
        Text(label, style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _KillWording {
  const _KillWording({
    required this.key,
    required this.signal,
    required this.button,
    required this.title,
    required this.message,
    required this.confirm,
    required this.color,
  });

  final String key;
  final int signal;
  final String button;
  final String title;
  final String Function(SimProcess proc) message;
  final String confirm;
  final Color color;
}

/// The gentle and the forced way to end a process; Windows has no signals, so it says taskkill.
List<_KillWording> _killWordings({required bool windows}) => windows
    ? [
        _KillWording(
          key: 'kill',
          signal: 15,
          button: 'END',
          title: 'End this process?',
          message: (p) => 'Ask PID ${p.pid} (${p.name}) to close with taskkill?',
          confirm: 'End',
          color: OmniColors.amber,
        ),
        _KillWording(
          key: 'forceKill',
          signal: 9,
          button: 'FORCE END',
          title: 'Force this process to end?',
          message: (p) =>
              'Force PID ${p.pid} (${p.name}) to end with taskkill /F? '
              'Unsaved work in that process is lost.',
          confirm: 'Force end',
          color: OmniColors.red,
        ),
      ]
    : [
        _KillWording(
          key: 'kill',
          signal: 15,
          button: 'KILL -15',
          title: 'Send SIGTERM?',
          message: (p) => 'Gracefully terminate PID ${p.pid} (${p.name}) with kill -15?',
          confirm: 'Kill -15',
          color: OmniColors.amber,
        ),
        _KillWording(
          key: 'forceKill',
          signal: 9,
          button: 'KILL -9',
          title: 'Force kill (SIGKILL)?',
          message: (p) =>
              'Forcibly kill PID ${p.pid} (${p.name}) with kill -9? '
              'Unsaved work in that process is lost.',
          confirm: 'Kill -9',
          color: OmniColors.red,
        ),
      ];

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
          'This host has no service manager OmniTerm can read (systemd, OpenRC, BSD rc.d, '
          'launchd or Windows services), so its services cannot be listed.',
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
            child: CommandOutputCard(
              // This is remote command output — `systemctl` will happily return a page of it on a
              // failure. It was rendered as a single proportional-font `Text` with no copy button
              // and no height bound, so a unit that failed to start pushed the service list off the
              // screen and the error could not be pasted anywhere. Kotlin puts the same output in a
              // scrollable monospace box with a Copy button (`ui/AppUi.kt:263`).
              keyPrefix: 'monitor.services.feedback',
              title: 'Service output',
              output: vm.actionFeedback!,
              onDismiss: vm.dismissActionFeedback,
            ),
          ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('monitor.services.list'),
            itemCount: vm.services.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final svc = vm.services[index];
              final running = svc.status == 'running';
              // Kotlin's card (`ServicesTab`, `ui/MonitorScreen.kt`): every action is a button, and
              // the ones that take a service down or off the boot list ask first.
              Widget action(
                String action,
                String label,
                Color color, {
                ({String title, String message})? confirm,
              }) => OmniButton(
                key: ValueKey('monitor.service.${svc.name}.$action'),
                label: label,
                color: color,
                small: true,
                onPressed: () async {
                  if (confirm != null &&
                      !await showOmniConfirm(
                        context,
                        title: confirm.title,
                        message: confirm.message,
                        confirmLabel: label,
                        keyPrefix: 'monitor.service.confirm',
                      )) {
                    return;
                  }
                  if (context.mounted) await _runServiceAction(context, vm, svc, action);
                },
              );
              return OmniCard(
                key: ValueKey('monitor.service.${svc.name}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  StatusDot(online: running, semanticLabel: svc.status),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      svc.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: OmniFonts.mono,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (svc.desc.isNotEmpty)
                                Text(
                                  svc.desc,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ),
                        OmniTag(label: svc.subState, color: _subStateColor(svc.subState, scheme)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        action(
                          'restart',
                          'Restart',
                          OmniColors.cyan,
                          confirm: (
                            title: 'Restart ${svc.name}?',
                            message: '${svc.name} will briefly stop and start again.',
                          ),
                        ),
                        if (running)
                          action(
                            'stop',
                            'Stop',
                            OmniColors.red,
                            confirm: (
                              title: 'Stop ${svc.name}?',
                              message: '${svc.name} will stay down until it is started again.',
                            ),
                          )
                        else
                          action('start', 'Start', OmniColors.green),
                        if (svc.enabled)
                          action(
                            'disable',
                            'Disable',
                            OmniColors.amber,
                            confirm: (
                              title: 'Disable ${svc.name}?',
                              message: 'Stop ${svc.name} from starting at boot.',
                            ),
                          )
                        else
                          action('enable', 'Enable', OmniColors.purple),
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

  Color _subStateColor(String subState, ColorScheme scheme) => switch (subState) {
    'active' => OmniColors.green,
    'failed' => OmniColors.red,
    _ => scheme.onSurfaceVariant,
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
