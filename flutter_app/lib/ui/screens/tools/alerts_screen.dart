import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/alert_evaluation.dart';
import '../../view_model/app_state.dart';
import '../../view_model/telemetry_poller.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/alerts_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Alerts tool, ported from `AlertsToolView` in `ui/ToolsScreen.kt`.
///
/// Three tabs: what is firing now, the rules that decide that, and the archive.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  /// Kotlin's `LaunchedEffect` runs a 60-second ticker updating `now` so muted alerts auto-expire
  /// visually. Without this, a muted alert stays tagged "MUTED" until the user triggers a rebuild.
  Timer? _muteExpiryTicker;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AlertsViewModel>();

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MasterSwitch(vm: vm),
            _NotificationWarning(vm: vm),
            _TabBar(vm: vm),
            if (vm.status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: OmniCard(
                  key: const ValueKey('alerts.status'),
                  leftAccent: OmniColors.green,
                  child: Row(
                    children: [
                      Expanded(child: Text(vm.status!, style: const TextStyle(fontSize: 12))),
                      IconButton(
                        tooltip: 'Dismiss',
                        key: const ValueKey('alerts.status.dismiss'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: vm.dismissStatus,
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: switch (vm.activeTab) {
                AlertsTab.active => _ActiveTab(vm: vm),
                AlertsTab.rules => _RulesTab(vm: vm),
                AlertsTab.history => _HistoryTab(vm: vm),
              },
            ),
          ],
        ),
        if (vm.activeTab == AlertsTab.rules)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              key: const ValueKey('alerts.addRule'),
              tooltip: 'New alert rule',
              onPressed: () => _openRuleEditor(context, vm),
              child: const Icon(Icons.add),
            ),
          ),
      ],
    );
  }
}

class _MasterSwitch extends StatelessWidget {
  const _MasterSwitch({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: OmniCard(
        key: const ValueKey('alerts.masterSwitch'),
        leftAccent: vm.alertsEnabled ? OmniColors.green : OmniColors.textMuted,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Alerting',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Text(
                    // Being explicit that nothing is evaluated while off: a silent alerts screen
                    // and a switched-off one look identical otherwise.
                    vm.alertsEnabled
                        ? 'Rules are evaluated on every telemetry poll.'
                        : 'Off — no rules are evaluated and nothing new will fire.',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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
      ),
    );
  }
}

/// Says when alerts will fire but nothing will reach the notification shade.
///
/// This is the least obvious kind of broken: everything works, the incident is recorded, the screen
/// updates — and the user finds out about their full disk the next time they happen to open the app.
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: OmniCard(
        key: const ValueKey('alerts.notificationWarning'),
        leftAccent: OmniColors.amber,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.notifications_off, size: 16, color: OmniColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 11, color: OmniColors.amber)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        key: const ValueKey('alerts.tabs'),
        children: [
          for (final tab in AlertsTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: ValueKey('alerts.tab.${tab.name}'),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(switch (tab) {
                      AlertsTab.active => 'Firing',
                      AlertsTab.rules => 'Rules',
                      AlertsTab.history => 'History',
                    }, style: const TextStyle(fontSize: 12)),
                    // The count leads with unmuted incidents: a muted one is something you already
                    // know about, so counting it would defeat the purpose of muting.
                    if (tab == AlertsTab.active && vm.unmutedCount > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: OmniColors.red,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${vm.unmutedCount}',
                          style: TextStyle(fontSize: 9, color: scheme.onPrimary),
                        ),
                      ),
                    ],
                  ],
                ),
                selected: vm.activeTab == tab,
                onSelected: (_) => vm.activeTab = tab,
              ),
            ),
        ],
      ),
    );
  }
}

class _RefreshButton extends StatefulWidget {
  const _RefreshButton({required this.serverId});
  final int serverId;

  @override
  State<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<_RefreshButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: ValueKey('alerts.active.refresh.${widget.serverId}'),
      icon: _busy
          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh, size: 12),
      label: const Text('Refresh', style: TextStyle(fontSize: 12)),
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              try {
                final srv = context
                    .read<AppState>()
                    .servers
                    .where((s) => s.id == widget.serverId)
                    .firstOrNull;
                if (srv != null) {
                  await context.read<TelemetryPoller>().pollOne(srv);
                }
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
    );
  }
}

class _ActiveTab extends StatelessWidget {
  const _ActiveTab({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.activeAlerts.isEmpty) {
      return Center(
        key: const ValueKey('alerts.active.empty'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, size: 36, color: OmniColors.green),
              const SizedBox(height: 10),
              Text(
                vm.rules.isEmpty
                    // "Nothing firing" reads as reassurance, which is misleading when there is
                    // nothing that *could* fire.
                    ? 'No alert rules yet, so nothing is being watched.'
                    : 'Nothing is firing.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    return ListView.separated(
      key: const ValueKey('alerts.active.list'),
      padding: const EdgeInsets.all(12),
      itemCount: vm.activeAlerts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final alert = vm.activeAlerts[index];
        final critical = alert.severity == 'CRITICAL';
        final muted = alert.mutedUntil > now;

        return OmniCard(
          key: ValueKey('alerts.active.${alert.id}'),
          leftAccent: critical ? OmniColors.red : OmniColors.amber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${alert.metricName} · ${vm.scopeLabel(alert.serverId)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  if (muted) ...[
                    const OmniTag(label: 'MUTED', color: OmniColors.textMuted),
                    const SizedBox(width: 6),
                  ],
                  if (alert.acknowledged) ...[
                    const OmniTag(label: 'SEEN', color: OmniColors.cyan),
                    const SizedBox(width: 6),
                  ],
                  OmniTag(
                    label: alert.severity,
                    color: critical ? OmniColors.red : OmniColors.amber,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${alert.currentValue.round()}${unitFor(alert.metricName)} '
                '(threshold ${alert.thresholdValue.round()}${unitFor(alert.metricName)})',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: OmniFonts.mono,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _RefreshButton(serverId: alert.serverId),
                  if (!alert.acknowledged)
                    TextButton(
                      key: ValueKey('alerts.active.${alert.id}.ack'),
                      onPressed: () => vm.acknowledge(alert),
                      child: const Text('Acknowledge', style: TextStyle(fontSize: 12)),
                    ),
                  TextButton(
                    key: ValueKey('alerts.active.${alert.id}.mute'),
                    onPressed: () => _openMuteMenu(context, vm, alert),
                    child: Text(muted ? 'Muted' : 'Mute', style: const TextStyle(fontSize: 12)),
                  ),
                  const Spacer(),
                  TextButton(
                    key: ValueKey('alerts.active.${alert.id}.dismiss'),
                    onPressed: () => vm.dismiss(alert),
                    child: const Text(
                      'Dismiss',
                      style: TextStyle(fontSize: 12, color: OmniColors.red),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _openMuteMenu(BuildContext context, AlertsViewModel vm, ActiveAlert alert) async {
  final duration = await showModalBottomSheet<Duration>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              // Saying what muting does and does not do: it is not an acknowledgement that the
              // problem is gone.
              'Muting keeps the incident listed but stops it re-alerting. It still resolves on its '
              'own when the metric recovers.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final (label, duration) in const [
            ('15 minutes', Duration(minutes: 15)),
            ('1 hour', Duration(hours: 1)),
            ('8 hours', Duration(hours: 8)),
            ('24 hours', Duration(hours: 24)),
          ])
            ListTile(
              key: ValueKey('alerts.mute.$label'),
              title: Text(label),
              onTap: () => Navigator.of(sheetContext).pop(duration),
            ),
        ],
      ),
    ),
  );
  if (duration != null) await vm.mute(alert, duration);
}

class _RulesTab extends StatelessWidget {
  const _RulesTab({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey('alerts.rules.list'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      children: [
        OmniCard(
          key: const ValueKey('alerts.presets'),
          leftAccent: OmniColors.cyan,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Default rules',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    Text(
                      'CPU, memory and disk at 90%, latency at 250ms, temperature at 80°.',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                key: const ValueKey('alerts.presets.switch'),
                value: vm.presetsEnabled,
                onChanged: vm.busy ? null : (on) => _confirmPresets(context, vm, on),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (vm.rules.isEmpty)
          Padding(
            key: const ValueKey('alerts.rules.empty'),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No rules yet. Turn on the defaults above, or add one.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          )
        else
          for (final rule in vm.rules) _RuleCard(vm: vm, rule: rule),
      ],
    );
  }

  Future<void> _confirmPresets(BuildContext context, AlertsViewModel vm, bool on) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('alerts.presets.dialog'),
        title: Text(on ? 'Enable default rules?' : 'Disable default rules?'),
        content: Text(
          on
              ? 'This adds the default rules and resets any thresholds you changed on them.'
              : 'This removes the default rules, including any you retuned. Your own rules are '
                    'kept.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('alerts.presets.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('alerts.presets.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              on ? 'Enable' : 'Disable',
              style: TextStyle(color: on ? null : OmniColors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.setPresetsEnabled(on);
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({required this.vm, required this.rule});

  final AlertsViewModel vm;
  final AlertRule rule;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final critical = rule.severity == 'CRITICAL';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('alerts.rule.${rule.id}'),
        leftAccent: rule.enabled
            ? (critical ? OmniColors.red : OmniColors.amber)
            : OmniColors.textMuted,
        onTap: () => _openRuleEditor(context, vm, existing: rule),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          describeRule(rule),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      if (vm.isPristinePresetRule(rule)) ...[
                        const SizedBox(width: 6),
                        const OmniTag(label: 'DEFAULT', color: OmniColors.textMuted),
                      ],
                    ],
                  ),
                  Text(
                    '${vm.scopeLabel(rule.serverId)} · ${rule.severity}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Switch(
              key: ValueKey('alerts.rule.${rule.id}.enabled'),
              value: rule.enabled,
              onChanged: (v) => vm.setRuleEnabled(rule, v),
            ),
            IconButton(
              key: ValueKey('alerts.rule.${rule.id}.delete'),
              tooltip: 'Delete rule',
              icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
              onPressed: () => _confirmDeleteRule(context, vm, rule),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmDeleteRule(BuildContext context, AlertsViewModel vm, AlertRule rule) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('alerts.deleteRule.dialog'),
      title: const Text('Delete this rule?'),
      content: Text(
        '${describeRule(rule)}\n\n'
        // Deleting a rule stops the watching, which is the part worth stating.
        'Nothing will watch this metric afterwards, and any incident it raised is closed.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('alerts.deleteRule.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('alerts.deleteRule.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.deleteRule(rule);
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.vm});

  final AlertsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.history.isEmpty) {
      return Center(
        key: const ValueKey('alerts.history.empty'),
        child: Text(
          'No past incidents.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('alerts.history.clear'),
            icon: const Icon(Icons.clear_all, size: 16),
            label: const Text('Clear history', style: TextStyle(fontSize: 12)),
            onPressed: vm.clearHistory,
          ),
        ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('alerts.history.list'),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            itemCount: vm.history.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final entry = vm.history[index];
              return OmniCard(
                key: ValueKey('alerts.history.${entry.id}'),
                leftAccent: entry.status == 'resolved' ? OmniColors.green : OmniColors.textMuted,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            // The archived host *name*, not a live lookup: the row must stay
                            // readable after the host is deleted.
                            '${entry.metricName} · ${entry.serverName}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          Text(
                            '${entry.currentValue.round()}${unitFor(entry.metricName)} '
                            'vs ${entry.thresholdValue.round()}${unitFor(entry.metricName)}',
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: OmniFonts.mono,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OmniTag(
                      label: entry.status.toUpperCase(),
                      color: entry.status == 'resolved' ? OmniColors.green : OmniColors.textMuted,
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
}

Future<void> _openRuleEditor(
  BuildContext context,
  AlertsViewModel vm, {
  AlertRule? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _RuleSheet(vm: vm, existing: existing),
  );
}

class _RuleSheet extends StatefulWidget {
  const _RuleSheet({required this.vm, this.existing});

  final AlertsViewModel vm;
  final AlertRule? existing;

  @override
  State<_RuleSheet> createState() => _RuleSheetState();
}

class _RuleSheetState extends State<_RuleSheet> {
  late String _metric = widget.existing?.metricName ?? 'CPU Usage';
  late String _severity = widget.existing?.severity ?? 'WARNING';
  late String _window = widget.existing?.triggerWindow ?? '5m';
  late int _serverId = widget.existing?.serverId ?? 0;
  late final _threshold = TextEditingController(
    text: (widget.existing?.thresholdValue ?? 90).round().toString(),
  );
  late final _mount = TextEditingController(text: widget.existing?.mountPoint ?? '/');
  String? _failure;

  @override
  void initState() {
    super.initState();
    // The preview restates the rule in words, which is the point of having it — so it has to track
    // the fields as they are typed, not only when a dropdown changes.
    _threshold.addListener(_onFieldChanged);
    _mount.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _threshold
      ..removeListener(_onFieldChanged)
      ..dispose();
    _mount
      ..removeListener(_onFieldChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final failure = await widget.vm.saveRule(
      existing: widget.existing,
      metricName: _metric,
      thresholdValue: double.tryParse(_threshold.text.trim()) ?? double.nan,
      severity: _severity,
      triggerWindow: _window,
      serverId: _serverId,
      mountPoint: _mount.text.trim().isEmpty ? '/' : _mount.text.trim(),
      enabled: widget.existing?.enabled ?? true,
      notes: widget.existing?.notes ?? '',
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _failure = failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hosts = widget.vm.hosts;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.existing == null ? 'New alert rule' : 'Edit alert rule',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('alerts.editor.metric'),
                initialValue: _metric,
                decoration: omniInputDecoration(context, labelText: 'Metric'),
                items: [
                  for (final metric in alertMetrics)
                    DropdownMenuItem(value: metric, child: Text(metric)),
                ],
                onChanged: (v) => setState(() => _metric = v ?? _metric),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('alerts.editor.threshold'),
                controller: _threshold,
                keyboardType: TextInputType.number,
                decoration: omniInputDecoration(
                  context,
                  labelText: 'Threshold (${unitFor(_metric)})',
                ),
              ),
              if (_metric == 'Disk Usage') ...[
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('alerts.editor.mount'),
                  controller: _mount,
                  decoration: omniInputDecoration(
                    context,
                    labelText: 'Mount point',
                    // Naming the mount matters: watching / says nothing about a full /srv.
                    hintText: '/ for the root filesystem',
                  ),
                ),
              ],
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('alerts.editor.severity'),
                initialValue: _severity,
                decoration: omniInputDecoration(context, labelText: 'Severity'),
                items: [
                  for (final severity in alertSeverities)
                    DropdownMenuItem(value: severity, child: Text(severity)),
                ],
                onChanged: (v) => setState(() => _severity = v ?? _severity),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('alerts.editor.window'),
                initialValue: _window,
                decoration: omniInputDecoration(
                  context,
                  labelText: 'Must breach for',
                  // Explaining the window is what stops rules being written that fire on one spike.
                  helperText: 'A shorter window fires on brief spikes.',
                ),
                items: [
                  for (final window in alertWindows)
                    DropdownMenuItem(value: window, child: Text(window)),
                ],
                onChanged: (v) => setState(() => _window = v ?? _window),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                key: const ValueKey('alerts.editor.scope'),
                initialValue: _serverId,
                decoration: omniInputDecoration(context, labelText: 'Applies to'),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('All hosts')),
                  for (final host in hosts)
                    DropdownMenuItem(value: host.id, child: Text(host.name)),
                ],
                onChanged: (v) => setState(() => _serverId = v ?? 0),
              ),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _failure!,
                    key: const ValueKey('alerts.editor.error'),
                    style: const TextStyle(color: OmniColors.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 14),
              Text(
                describeRule(
                  AlertRule(
                    id: 0,
                    serverId: _serverId,
                    metricName: _metric,
                    mountPoint: _mount.text.trim().isEmpty ? '/' : _mount.text.trim(),
                    thresholdValue: double.tryParse(_threshold.text.trim()) ?? 0,
                    severity: _severity,
                    triggerWindow: _window,
                    enabled: true,
                    notes: '',
                  ),
                ),
                key: const ValueKey('alerts.editor.preview'),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              FilledButton(
                key: const ValueKey('alerts.editor.save'),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
