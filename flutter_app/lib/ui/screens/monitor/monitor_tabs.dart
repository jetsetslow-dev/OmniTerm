import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
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

/// The Monitor sub-tabs, ported from `OverviewTab` / `ProcessesTab` / `ServicesTab` / `LogsTab` in
/// `ui/MonitorScreen.kt`.

/// Says when these numbers were taken and when they will be taken again.
///
/// Ported from the Kotlin's refresh ring. It exists because a screen of live-looking figures gives
/// no way to tell a host that is idle from one that stopped answering four minutes ago — the numbers
/// look identical. The countdown is derived from the poller's own cycle rather than from a timer of
/// its own, so it cannot drift away from the thing it is describing.
class _RefreshCountdown extends StatefulWidget {
  const _RefreshCountdown({required this.vm});

  final MonitorViewModel vm;

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
    final taken = widget.vm.metricsSampledAt;
    // No poller in this build: no countdown to show, and inventing one would be a promise the app
    // cannot keep.
    if (next == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final remaining = next.difference(now);
    final age = taken == null ? null : now.difference(taken);

    return Padding(
      key: const ValueKey('monitor.overview.countdown'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        [
          if (age == null) 'Waiting for the first sample' else 'Sampled ${_ago(age)}',
          if (!remaining.isNegative) 'next in ${remaining.inSeconds + 1}s' else 'refreshing…',
        ].join(' · '),
        style: TextStyle(
          fontSize: 10,
          fontFamily: OmniFonts.mono,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  static String _ago(Duration age) {
    if (age.inSeconds < 5) return 'just now';
    if (age.inMinutes < 1) return '${age.inSeconds}s ago';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    return '${age.inHours}h ago';
  }
}

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
        _RefreshCountdown(vm: vm),
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
                          // Obeys the Measurement system setting, as Kotlin does — a user who chose
                          // imperial was previously still shown Celsius here.
                          'Temp: ${formatTemperature(m.cpuTempC!, vm.measurementSystem)}',
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
        const SizedBox(height: 12),
        _DiskCard(metrics: m),
        const SizedBox(height: 12),
        _RetainedHistoryCard(vm: vm, accent: accent),
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
  if (server != null && lock.requiresSudoAuth(server.sudoPassword)) {
    if (!await requestSudoAuth(context, lock)) return;
  }
  await vm.runServiceAction(service, action);
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
        if (vm.processes.isEmpty)
          Expanded(
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
                              onPressed: () => _confirmKill(context, vm, proc, force: false),
                              child: const Text('Kill', style: TextStyle(color: OmniColors.red)),
                            ),
                            // SIGTERM is exactly the signal a wedged process ignores, so an app
                            // that only sends it cannot end the one case you reach for it.
                            TextButton(
                              key: ValueKey('monitor.process.${proc.pid}.forceKill'),
                              onPressed: () => _confirmKill(context, vm, proc, force: true),
                              child: const Text('Force', style: TextStyle(color: OmniColors.red)),
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

  /// Confirms, then signals [proc].
  ///
  /// [force] selects SIGKILL over SIGTERM. Kotlin offers both as separate actions with separate
  /// prompts (`ui/MonitorScreen.kt:920` and `:934`); the port wired only the graceful one, leaving
  /// `killProcess`'s `signal` parameter with no caller that ever changed it.
  ///
  /// They are deliberately not one dialog with a checkbox: the two differ in whether the process
  /// gets to save anything, which is a choice to make before confirming, not while confirming.
  Future<void> _confirmKill(
    BuildContext context,
    MonitorViewModel vm,
    SimProcess proc, {
    required bool force,
  }) async {
    // Killing the wrong pid can take a host offline, and the list is sorted live — a row can move
    // under the finger between reading and tapping. So the dialog names what will be killed.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('monitor.kill.dialog'),
        title: Text(force ? 'Force kill (SIGKILL)?' : 'Kill ${proc.name}?'),
        content: Text(
          force
              // Kotlin's warning, kept: the consequence is the whole difference between the two.
              ? 'Forcibly kills pid ${proc.pid} (${proc.name}) with kill -9. '
                    'Unsaved work in that process is lost.'
              : 'Sends SIGTERM to pid ${proc.pid} (${proc.owner}).',
        ),
        actions: [
          TextButton(
            key: const ValueKey('monitor.kill.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('monitor.kill.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              force ? 'Force kill' : 'Kill',
              style: const TextStyle(color: OmniColors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await vm.killProcess(proc.pid, signal: force ? 9 : 15);
    }
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
                      onSelected: (action) => _runServiceAction(context, vm, svc, action),
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
