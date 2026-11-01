import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/alert_evaluation.dart';
import '../../../domain/measurement_units.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/alerts_view_model.dart';
import '../../view_model/app_state.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';

/// Kotlin's `formatShortDateTime`: `MMM d, HH:mm` in the device locale.
String formatShortDateTime(int timeMs) =>
    DateFormat('MMM d, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(timeMs));

/// The Alerts Center, ported from `AlertsToolView` in `ui/ToolsScreen.kt`.
///
/// Three tabs: what is firing now, the rules that decide that, and the archive.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  /// A mute can expire without a database emission (for example while the host is offline), so a
  /// minute tick keeps the Active/Muted partition honest, as Kotlin's `LaunchedEffect` does.
  Timer? _muteExpiryTicker;

  /// Returning from system settings is how a user unblocks notifications; re-read on resume.
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted) context.read<AlertsViewModel>().refreshNotificationsAllowed();
      },
    );
    _muteExpiryTicker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AlertsViewModel>().start();
    });
  }

  @override
  void dispose() {
    _muteExpiryTicker?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AlertsViewModel>();
    final system = context.select<AppState, MeasurementSystem>((a) => a.measurementSystem);
    final now = DateTime.now().millisecondsSinceEpoch;
    final alerts = vm.activeAlerts;
    final visible = [
      for (final a in alerts)
        if (!a.acknowledged && a.mutedUntil < now) a,
    ];
    final acknowledged = [
      for (final a in alerts)
        if (a.acknowledged && a.mutedUntil < now) a,
    ];
    final muted = [
      for (final a in alerts)
        if (a.mutedUntil >= now) a,
    ];

    return ToolScaffold(
      title: 'Alerts Center',
      keyPrefix: 'alerts',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      onAdd: vm.activeTab == AlertsTab.rules ? () => _openRuleDialog(context, vm, system) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ShortViewportScroll(
          // The monitoring card above the tabs is the tallest fixed chrome of any tool screen.
          minHeight: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MonitoringCard(vm: vm),
              _NotificationWarning(vm: vm),
              OmniTabRow(
                key: const ValueKey('alerts.tabs'),
                labels: ['Active (${visible.length})', 'Rules', 'History'],
                selectedIndex: vm.activeTab.index,
                onSelected: (i) => vm.activeTab = AlertsTab.values[i],
                tabKeys: [for (final tab in AlertsTab.values) ValueKey('alerts.tab.${tab.name}')],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: switch (vm.activeTab) {
                  AlertsTab.active => _ActiveTab(
                    vm: vm,
                    system: system,
                    visible: visible,
                    acknowledged: acknowledged,
                    muted: muted,
                  ),
                  AlertsTab.rules => _RulesTab(vm: vm, system: system),
                  AlertsTab.history => _HistoryTab(vm: vm, system: system),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Honest scope: rules are evaluated by the in-app telemetry poller, so alerts only fire while
/// OmniTerm is open.
class _MonitoringCard extends StatelessWidget {
  const _MonitoringCard({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return OmniCard(
      inset: const EdgeInsets.all(12),
      key: const ValueKey('alerts.masterSwitch'),
      margin: const EdgeInsets.only(bottom: 8),
      leftAccent: OmniColors.amber,
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
                      'In-app monitoring',
                      style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    Text(
                      vm.alertsEnabled ? 'Global alerts are on.' : 'Global alerts are off.',
                      style: composeBody(
                        fontSize: 11,
                        color: vm.alertsEnabled ? muted : OmniColors.red,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const ValueKey('alerts.masterSwitch.toggle'),
                value: vm.alertsEnabled,
                onChanged: vm.setAlertsEnabled,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Rules are checked on each metrics refresh while OmniTerm is open. Alerts will not '
            'fire in the background or when the app is closed — keep the app running to monitor.',
            style: composeBody(fontSize: 11, color: muted),
          ),
        ],
      ),
    );
  }
}

/// Says when alerts will fire but nothing will reach the notification shade.
///
/// Kotlin's `AlertNotificationBlockedNote` shows the same note. It renders nothing unless
/// notifications are blocked (or the build cannot post them), so the normal screen is unchanged.
class _NotificationWarning extends StatelessWidget {
  const _NotificationWarning({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    if (!vm.alertsEnabled) return const SizedBox.shrink();
    final message = switch ((vm.canNotify, vm.notificationsAllowed)) {
      (false, _) =>
        'Notifications are not available in this build. Rules still fire and incidents '
            'are still recorded, but nothing will appear outside the app.',
      (true, false) =>
        'Notifications are blocked for OmniTerm. Rules still fire and incidents are '
            'still recorded, but you will only see them in here. Allow notifications in system '
            'settings to be told while the app is closed.',
      _ => null,
    };
    if (message == null) return const SizedBox.shrink();
    return OmniCard(
      key: const ValueKey('alerts.notificationWarning'),
      margin: const EdgeInsets.only(bottom: 8),
      leftAccent: OmniColors.amber,
      child: Text(message, style: composeBody(fontSize: 11, color: OmniColors.amber)),
    );
  }
}

Widget _centeredNote(BuildContext context, String text, Key key) => Center(
  key: key,
  child: Text(
    text,
    textAlign: TextAlign.center,
    style: composeBody(color: Theme.of(context).colorScheme.onSurfaceVariant),
  ),
);

Widget _spacedList(Key key, List<Widget> children) => ListView.separated(
  key: key,
  itemCount: children.length,
  separatorBuilder: (_, _) => const SizedBox(height: 8),
  itemBuilder: (_, i) => children[i],
);

class _ActiveTab extends StatelessWidget {
  const _ActiveTab({
    required this.vm,
    required this.system,
    required this.visible,
    required this.acknowledged,
    required this.muted,
  });

  final AlertsViewModel vm;
  final MeasurementSystem system;
  final List<ActiveAlert> visible;
  final List<ActiveAlert> acknowledged;
  final List<ActiveAlert> muted;

  @override
  Widget build(BuildContext context) {
    if (visible.isEmpty && muted.isEmpty) {
      return _centeredNote(
        context,
        'No active alert incidents.',
        const ValueKey('alerts.active.empty'),
      );
    }
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    String serverName(ActiveAlert a) => vm.serverFor(a.serverId)?.name ?? 'server';

    return _spacedList(const ValueKey('alerts.active.list'), [
      if (visible.isNotEmpty)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const ValueKey('alerts.active.ackAll'),
            onPressed: vm.acknowledgeAll,
            child: const Text('Ack All'),
          ),
        ),
      for (final alert in visible)
        OmniCard(
          inset: const EdgeInsets.all(12),
          key: ValueKey('alerts.active.${alert.id}'),
          leftAccent: alert.severity == 'CRITICAL' ? OmniColors.red : OmniColors.amber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.metricName,
                      style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Text(
                    alert.severity,
                    style: composeBody(
                      color: alert.severity == 'CRITICAL'
                          ? const Color(0xFFFF0000)
                          : const Color(0xFFF59E0B),
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              Text(
                'Threshold: ${alertMetricDisplay(alert.metricName, alert.thresholdValue, system)} · '
                'Current: ${alertMetricDisplay(alert.metricName, alert.currentValue, system)}',
                style: composeBody(fontSize: 12, color: meta),
              ),
              Text('Server: ${serverName(alert)}', style: composeBody(fontSize: 12, color: meta)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: ValueKey('alerts.active.${alert.id}.ack'),
                    onPressed: () => vm.acknowledge(alert),
                    child: const Text('ACKNOWLEDGE'),
                  ),
                  TextButton(
                    key: ValueKey('alerts.active.${alert.id}.mute'),
                    onPressed: () => vm.mute(alert, const Duration(hours: 1)),
                    child: const Text('MUTE 1H'),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (muted.isNotEmpty)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            'Muted incidents',
            style: composeBody(fontWeight: FontWeight.bold, color: OmniColors.purple),
          ),
        ),
      for (final alert in muted)
        OmniCard(
          inset: const EdgeInsets.all(12),
          key: ValueKey('alerts.muted.${alert.id}'),
          leftAccent: OmniColors.purple,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.metricName,
                      style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Text(
                    'MUTED',
                    style: composeBody(
                      color: OmniColors.purple,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              Text('Server: ${serverName(alert)}', style: composeBody(fontSize: 12, color: meta)),
              Text(
                'Until ${formatShortDateTime(alert.mutedUntil)}',
                style: composeBody(fontSize: 11, color: meta),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: ValueKey('alerts.muted.${alert.id}.unmute'),
                  onPressed: () => vm.unmute(alert),
                  child: const Text('UNMUTE'),
                ),
              ),
            ],
          ),
        ),
      if (acknowledged.isNotEmpty)
        Padding(
          key: const ValueKey('alerts.active.acknowledgedNote'),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            '${acknowledged.length} acknowledged incident(s) hidden until recovery.',
            style: composeBody(fontSize: 11, color: meta),
          ),
        ),
    ]);
  }
}

class _RulesTab extends StatelessWidget {
  const _RulesTab({required this.vm, required this.system});

  final AlertsViewModel vm;
  final MeasurementSystem system;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    return _spacedList(const ValueKey('alerts.rules.list'), [
      OmniCard(
        inset: const EdgeInsets.all(12),
        key: const ValueKey('alerts.presets'),
        leftAccent: OmniColors.purple,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Default alert rules',
                    style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Text(
                    'CPU/memory/disk 90%, latency 250ms, temperature '
                    '${formatTemperature(80, system)}. Created as editable All Hosts rules.',
                    style: composeBody(fontSize: 11, color: meta),
                  ),
                ],
              ),
            ),
            Switch(
              key: const ValueKey('alerts.presets.switch'),
              value: vm.presetsEnabled,
              onChanged: vm.busy ? null : (on) => _confirmPresets(context, on),
            ),
          ],
        ),
      ),
      for (final rule in vm.rules)
        OmniCard(
          inset: const EdgeInsets.all(12),
          key: ValueKey('alerts.rule.${rule.id}'),
          leftAccent: OmniColors.cyan,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.metricName,
                      style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    Text(
                      '${rule.serverId == 0 ? 'All Hosts' : vm.serverFor(rule.serverId)?.name ?? 'host'}'
                      ' · Threshold > '
                      '${alertMetricDisplay(rule.metricName, rule.thresholdValue, system)} '
                      'for ${rule.triggerWindow}',
                      style: composeBody(fontSize: 11, color: meta),
                    ),
                    if (rule.notes.trim().isNotEmpty)
                      Text(
                        rule.notes,
                        style: composeBody(fontSize: 11, color: meta, fontStyle: FontStyle.italic),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('alerts.rule.${rule.id}.edit'),
                tooltip: 'Edit rule',
                onPressed: () => _openRuleDialog(context, vm, system, existing: rule),
                icon: const Icon(Icons.edit, color: OmniColors.cyan),
              ),
              IconButton(
                key: ValueKey('alerts.rule.${rule.id}.delete'),
                tooltip: 'Delete rule',
                onPressed: () => _confirmDelete(context, rule),
                icon: const Icon(Icons.delete, color: Color(0xFFFF0000)),
              ),
            ],
          ),
        ),
    ]);
  }

  Future<void> _confirmPresets(BuildContext context, bool on) async {
    final confirmed = on
        ? await showOmniConfirm(
            context,
            title: 'Enable default rules?',
            message:
                'This creates editable All Hosts alert rules for CPU, memory, disk, latency, and '
                'temperature, resetting any earlier edits to them.',
            confirmLabel: 'Enable',
            keyPrefix: 'alerts.presets',
          )
        : await showOmniConfirm(
            context,
            title: 'Disable default rules?',
            message:
                'This removes the default CPU/memory/disk/latency/temperature All Hosts rules, '
                'including any edits to them. Custom rules you added are kept.',
            confirmLabel: 'Disable',
            destructive: true,
            keyPrefix: 'alerts.presets',
          );
    if (confirmed) await vm.setPresetsEnabled(on);
  }

  Future<void> _confirmDelete(BuildContext context, AlertRule rule) async {
    // Kotlin names the looked-up host, so an All Hosts rule reads "for this host".
    final confirmed = await showOmniConfirm(
      context,
      title: 'Delete rule?',
      message:
          'Delete the ${rule.metricName} alert rule for '
          '${vm.serverFor(rule.serverId)?.name ?? 'this host'}?',
      confirmLabel: 'Delete',
      destructive: true,
      keyPrefix: 'alerts.deleteRule',
    );
    if (confirmed) await vm.deleteRule(rule);
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.vm, required this.system});

  final AlertsViewModel vm;
  final MeasurementSystem system;

  @override
  Widget build(BuildContext context) {
    if (vm.history.isEmpty) {
      return _centeredNote(
        context,
        'No alert history yet.',
        const ValueKey('alerts.history.empty'),
      );
    }
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    return _spacedList(const ValueKey('alerts.history.list'), [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          key: const ValueKey('alerts.history.clear'),
          onPressed: () async {
            final confirmed = await showOmniConfirm(
              context,
              title: 'Clear history?',
              message: 'Delete all alert history?',
              confirmLabel: 'Clear',
              destructive: true,
              keyPrefix: 'alerts.history.clearDialog',
            );
            if (confirmed) await vm.clearHistory();
          },
          child: const Text('Clear History'),
        ),
      ),
      for (final entry in vm.history)
        Builder(
          builder: (context) {
            final accent = switch (entry) {
              _ when entry.status == 'muted' => OmniColors.purple,
              _ when entry.status == 'resolved' => OmniColors.green,
              _ when entry.severity == 'CRITICAL' => OmniColors.red,
              _ => OmniColors.amber,
            };
            return OmniCard(
              inset: const EdgeInsets.all(12),
              key: ValueKey('alerts.history.${entry.id}'),
              leftAccent: accent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.metricName,
                              style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            // The archived host name, not a live lookup: the row must stay
                            // readable after the host is deleted.
                            Text(entry.serverName, style: composeBody(fontSize: 12, color: meta)),
                          ],
                        ),
                      ),
                      Text(
                        entry.status.toUpperCase(),
                        style: composeBody(
                          color: accent,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'Current ${alertMetricDisplay(entry.metricName, entry.currentValue, system)} · '
                    'threshold ${alertMetricDisplay(entry.metricName, entry.thresholdValue, system)} · '
                    '${entry.severity}',
                    style: composeBody(fontSize: 12, color: meta),
                  ),
                  Text(
                    'Triggered ${formatShortDateTime(entry.triggeredTime)} · '
                    'recorded ${formatShortDateTime(entry.historyTime)}',
                    style: composeBody(fontSize: 11, color: meta),
                  ),
                ],
              ),
            );
          },
        ),
    ]);
  }
}

Future<void> _openRuleDialog(
  BuildContext context,
  AlertsViewModel vm,
  MeasurementSystem system, {
  AlertRule? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RuleDialog(vm: vm, system: system, existing: existing),
);

/// Kotlin's add/edit rule `AlertDialog`. Creating may pick several hosts (one rule each, or a single
/// All Hosts rule); editing keeps the rule's single-host identity.
class _RuleDialog extends StatefulWidget {
  const _RuleDialog({required this.vm, required this.system, this.existing});

  final AlertsViewModel vm;
  final MeasurementSystem system;
  final AlertRule? existing;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final Set<int> _hosts = {widget.existing?.serverId ?? 0};
  late String _metric = widget.existing?.metricName ?? 'CPU Usage';
  late String _window = widget.existing?.triggerWindow ?? '5m';
  late final _threshold = TextEditingController(text: _initialThreshold());
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  bool _saving = false;
  String? _failure;

  String _initialThreshold() {
    final rule = widget.existing;
    if (rule == null) return '80';
    final shown = rule.metricName == 'Temperature'
        ? celsiusToDisplay(rule.thresholdValue, widget.system)
        : rule.thresholdValue;
    return kotlinFloatText(shown);
  }

  @override
  void initState() {
    super.initState();
    _threshold.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _threshold
      ..removeListener(_rebuild)
      ..dispose();
    _notes.dispose();
    super.dispose();
  }

  void _toggleHost(int id) => setState(() {
    if (widget.existing != null || id == 0) {
      // Editing is single-select, and "All hosts" is exclusive of concrete picks.
      _hosts
        ..clear()
        ..add(id);
    } else {
      _hosts.remove(0);
      if (!_hosts.remove(id)) _hosts.add(id);
    }
  });

  void _selectMetric(String metric) {
    if (metric == _metric) return;
    setState(() {
      _metric = metric;
      _threshold.text = switch (metric) {
        'Latency' => '250',
        'Temperature' => kotlinFloatText(celsiusToDisplay(80, widget.system)),
        _ => '90',
      };
    });
  }

  Future<void> _confirm() async {
    final entered = double.tryParse(_threshold.text.trim());
    if (entered == null || _saving) return;
    final threshold = _metric == 'Temperature'
        ? displayTemperatureToCelsius(entered, widget.system)
        : entered;
    setState(() {
      _saving = true;
      _failure = null;
    });
    String? failure;
    try {
      final existing = widget.existing;
      if (existing == null) {
        final targets = _hosts.contains(0) ? const [0] : _hosts.toList();
        for (final serverId in targets) {
          failure = await widget.vm.saveRule(
            metricName: _metric,
            thresholdValue: threshold,
            severity: 'CRITICAL',
            triggerWindow: _window,
            serverId: serverId,
            notes: _notes.text.trim(),
          );
          if (failure != null) break;
        }
      } else {
        failure = await widget.vm.saveRule(
          existing: existing,
          metricName: _metric,
          thresholdValue: threshold,
          severity: existing.severity,
          triggerWindow: _window,
          serverId: _hosts.first,
          mountPoint: existing.mountPoint,
          enabled: existing.enabled,
          notes: _notes.text.trim(),
        );
      }
    } catch (_) {
      failure = 'Could not save the rule. Check storage and try again.';
    }
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _failure = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final thresholdError = alertThresholdError(_threshold.text, _metric, widget.system);
    return AlertDialog(
      key: const ValueKey('alerts.editor'),
      scrollable: true,
      title: Text(widget.existing == null ? 'Add Alert Rule Trigger' : 'Edit Alert Rule'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          HostPickerField(
            fieldKey: const ValueKey('alerts.editor.hosts'),
            label: widget.existing == null ? 'Hosts' : 'Host',
            servers: widget.vm.hosts,
            selectedIds: _hosts,
            singleSelect: widget.existing != null,
            allHostsOption: true,
            onToggle: _toggleHost,
          ),
          const Text('Select Metric Key:'),
          Wrap(
            spacing: 6,
            children: [
              for (final metric in alertMetrics)
                FilterChip(
                  key: ValueKey('alerts.editor.metric.$metric'),
                  selected: _metric == metric,
                  onSelected: (_) => _selectMetric(metric),
                  label: Text(metric),
                ),
            ],
          ),
          // CPU temperature comes from the host's thermal sensors, which many hosts do not expose.
          if (_metric == 'Temperature')
            Text(
              'Only triggers on hosts that report a CPU temperature. Hosts without a thermal '
              'sensor (many VMs and containers) never evaluate this rule.',
              style: composeDialogBody(fontSize: 11, color: OmniColors.amber),
            ),
          TextField(
            key: const ValueKey('alerts.editor.threshold'),
            controller: _threshold,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: omniInputDecoration(
              context,
              labelText: 'Threshold value (${alertMetricUnit(_metric, widget.system)})',
              errorText: thresholdError,
            ),
          ),
          const Text('Trigger after breaching for:'),
          Wrap(
            spacing: 6,
            children: [
              for (final window in alertWindows)
                FilterChip(
                  key: ValueKey('alerts.editor.window.$window'),
                  selected: _window == window,
                  onSelected: (_) => setState(() => _window = window),
                  label: Text(window),
                ),
            ],
          ),
          TextField(
            key: const ValueKey('alerts.editor.notes'),
            controller: _notes,
            minLines: 2,
            maxLines: null,
            decoration: omniInputDecoration(
              context,
              labelText: 'Notes (optional)',
              hintText: 'Why this rule exists / what it watches for',
            ),
          ),
          if (_failure != null)
            Text(
              _failure!,
              key: const ValueKey('alerts.editor.error'),
              style: composeDialogBody(color: OmniColors.red, fontSize: 12),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('alerts.editor.cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('alerts.editor.save'),
          onPressed: _hosts.isNotEmpty && thresholdError == null && !_saving ? _confirm : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
