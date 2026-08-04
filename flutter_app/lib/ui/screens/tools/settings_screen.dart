import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/app_preferences.dart';
import '../../theme/colors.dart';
import '../../view_model/settings_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Settings tool, ported from `SettingsToolView` in `ui/ToolsScreen.kt`.
///
/// Edits are staged and applied on save, matching the Kotlin: several of these feed live timers and
/// buffers, and applying them per keystroke would restart the telemetry poller on the way from "1"
/// to "15".
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SettingsViewModel>().start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SettingsViewModel>();
    final draft = vm.draft;

    return Stack(
      children: [
        ListView(
          key: const ValueKey('settings.list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            if (vm.status != null) _StatusCard(vm: vm),
            for (final warning in vm.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  key: ValueKey('settings.warning.${vm.warnings.indexOf(warning)}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 14, color: OmniColors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warning,
                        style: const TextStyle(fontSize: 11, color: OmniColors.amber),
                      ),
                    ),
                  ],
                ),
              ),

            const SectionHeader(title: 'Appearance'),
            _Switch(
              settingKey: 'darkMode',
              title: 'Dark theme',
              value: draft.darkMode,
              onChanged: (v) => vm.update((p) => p.copyWith(darkMode: v)),
            ),
            _Switch(
              settingKey: 'amoled',
              title: 'AMOLED black',
              subtitle: 'True black backgrounds, which save power on OLED screens',
              value: draft.amoled,
              enabled: draft.darkMode,
              onChanged: (v) => vm.update((p) => p.copyWith(amoled: v)),
            ),
            _Switch(
              settingKey: 'accessibility',
              title: 'Larger touch targets',
              value: draft.accessibility,
              onChanged: (v) => vm.update((p) => p.copyWith(accessibility: v)),
            ),
            _Stepper(
              settingKey: 'textScale',
              title: 'Text size',
              suffix: '%',
              value: draft.textScalePercent,
              limits: PreferenceLimits.textScalePercent,
              step: 10,
              onChanged: (v) => vm.update((p) => p.copyWith(textScalePercent: v)),
            ),
            _Choice<MeasurementSystem>(
              settingKey: 'measurementSystem',
              title: 'Units',
              value: draft.measurementSystem,
              options: {
                for (final system in MeasurementSystem.values) system: system.label,
              },
              onChanged: (v) => vm.update((p) => p.copyWith(measurementSystem: v)),
            ),

            const SectionHeader(title: 'Monitoring'),
            _Stepper(
              settingKey: 'telemetryInterval',
              title: 'Poll every',
              suffix: 's',
              value: draft.telemetryIntervalSeconds,
              limits: PreferenceLimits.telemetryInterval,
              step: 5,
              onChanged: (v) => vm.update((p) => p.copyWith(telemetryIntervalSeconds: v)),
            ),
            _Stepper(
              settingKey: 'metricsRetention',
              title: 'Keep metrics for',
              suffix: ' days',
              value: draft.metricsRetentionDays,
              limits: PreferenceLimits.metricsRetention,
              step: 1,
              onChanged: (v) => vm.update((p) => p.copyWith(metricsRetentionDays: v)),
            ),
            _Stepper(
              settingKey: 'alertHistoryLimit',
              title: 'Alert history per host',
              value: draft.alertHistoryLimit,
              limits: PreferenceLimits.alertHistoryLimit,
              step: 10,
              onChanged: (v) => vm.update((p) => p.copyWith(alertHistoryLimit: v)),
            ),
            _Switch(
              settingKey: 'backgroundKeepAlive',
              title: 'Keep polling in the background',
              subtitle: 'Uses more battery, and the system may still stop it',
              value: draft.backgroundKeepAlive,
              onChanged: (v) => vm.update((p) => p.copyWith(backgroundKeepAlive: v)),
            ),
            _Switch(
              settingKey: 'batterySaverEnabled',
              title: 'Back off on low battery',
              value: draft.batterySaverEnabled,
              onChanged: (v) => vm.update((p) => p.copyWith(batterySaverEnabled: v)),
            ),
            if (draft.batterySaverEnabled)
              _Stepper(
                settingKey: 'batterySaverThreshold',
                title: 'Back off below',
                suffix: '%',
                value: draft.batterySaverThresholdPercent,
                limits: PreferenceLimits.batterySaverThreshold,
                step: 5,
                onChanged: (v) =>
                    vm.update((p) => p.copyWith(batterySaverThresholdPercent: v)),
              ),

            const SectionHeader(title: 'Terminal'),
            _Stepper(
              settingKey: 'terminalFontSize',
              title: 'Font size',
              value: draft.terminalFontSize,
              limits: PreferenceLimits.terminalFontSize,
              step: 1,
              onChanged: (v) => vm.update((p) => p.copyWith(terminalFontSize: v)),
            ),
            _Choice<String>(
              settingKey: 'terminalTheme',
              title: 'Colour scheme',
              value: draft.terminalTheme,
              options: {for (final theme in terminalThemes) theme: theme},
              onChanged: (v) => vm.update((p) => p.copyWith(terminalTheme: v)),
            ),
            _Stepper(
              settingKey: 'terminalScrollbackLimit',
              title: 'Scrollback lines',
              subtitle: 'Higher uses more memory; the cap is a device limit, not a preference',
              value: draft.terminalScrollbackLimit,
              limits: PreferenceLimits.terminalScrollback,
              step: 500,
              onChanged: (v) => vm.update((p) => p.copyWith(terminalScrollbackLimit: v)),
            ),
            _Switch(
              settingKey: 'smartSwipe',
              title: 'Swipe gestures for keys',
              value: draft.smartSwipeInput,
              onChanged: (v) => vm.update((p) => p.copyWith(smartSwipeInput: v)),
            ),
            _Switch(
              settingKey: 'linkDetection',
              title: 'Detect links in output',
              value: draft.terminalLinkDetection,
              onChanged: (v) => vm.update((p) => p.copyWith(terminalLinkDetection: v)),
            ),
            _Switch(
              settingKey: 'linkOpenInApp',
              title: 'Open links in the app',
              value: draft.linkOpenInApp,
              enabled: draft.terminalLinkDetection,
              onChanged: (v) => vm.update((p) => p.copyWith(linkOpenInApp: v)),
            ),
            _Switch(
              settingKey: 'tmuxControlMode',
              title: 'tmux control mode',
              subtitle: 'Renders tmux windows natively where the host supports it',
              value: draft.tmuxControlMode,
              onChanged: (v) => vm.update((p) => p.copyWith(tmuxControlMode: v)),
            ),
            _Stepper(
              settingKey: 'editorHighlightLimit',
              title: 'Highlight files up to',
              suffix: ' KB',
              subtitle: 'Highlighting a large file blocks the frame long enough to look like a hang',
              value: draft.editorHighlightLimitKb,
              limits: PreferenceLimits.editorHighlightLimit,
              step: 64,
              onChanged: (v) => vm.update((p) => p.copyWith(editorHighlightLimitKb: v)),
            ),

            const SectionHeader(title: 'Privacy and security'),
            _Switch(
              settingKey: 'appLockEnabled',
              title: 'Lock the app',
              subtitle: 'Requires a PIN when the app is reopened',
              value: draft.appLockEnabled,
              onChanged: (v) => vm.update((p) => p.copyWith(appLockEnabled: v)),
            ),
            _Switch(
              settingKey: 'biometrics',
              title: 'Unlock with biometrics',
              value: draft.useBiometrics,
              enabled: draft.appLockEnabled,
              onChanged: (v) => vm.update((p) => p.copyWith(useBiometrics: v)),
            ),
            _Switch(
              settingKey: 'blockScreenshots',
              title: 'Block screenshots',
              subtitle: 'Also hides the app from the recent-apps preview',
              value: draft.blockScreenshots,
              onChanged: (v) => vm.update((p) => p.copyWith(blockScreenshots: v)),
            ),
            _Switch(
              settingKey: 'hideSensitiveInfo',
              title: 'Hide addresses',
              // Naming the situation this is for, since the setting reads as vague otherwise.
              subtitle: 'Masks host addresses on screen — useful when sharing a screen or a photo',
              value: draft.hideSensitiveInfo,
              onChanged: (v) => vm.update((p) => p.copyWith(hideSensitiveInfo: v)),
            ),

            const SectionHeader(title: 'File transfers'),
            _Stepper(
              settingKey: 'sftpWarnFileCount',
              title: 'Warn above',
              suffix: ' files',
              value: draft.sftpWarnFileCount,
              limits: PreferenceLimits.sftpWarnFileCount,
              step: 10,
              onChanged: (v) => vm.update((p) => p.copyWith(sftpWarnFileCount: v)),
            ),
            _Stepper(
              settingKey: 'sftpWarnGigabytes',
              title: 'Warn above',
              suffix: ' GB',
              value: draft.sftpWarnGigabytes,
              limits: PreferenceLimits.sftpWarnGigabytes,
              step: 1,
              onChanged: (v) => vm.update((p) => p.copyWith(sftpWarnGigabytes: v)),
            ),

            const SizedBox(height: 16),
            TextButton(
              key: const ValueKey('settings.reset'),
              onPressed: () => _confirmReset(context, vm),
              child: const Text('Reset all settings', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Row(
            children: [
              if (vm.isDirty) ...[
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('settings.revert'),
                    onPressed: vm.revert,
                    child: const Text('Discard'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: FilledButton(
                  key: const ValueKey('settings.save'),
                  onPressed: vm.isDirty ? () => vm.save() : null,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmReset(BuildContext context, SettingsViewModel vm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('settings.reset.dialog'),
        title: const Text('Reset all settings?'),
        content: const Text(
          // Being specific about the blast radius: this screen's settings only, not the data.
          'Every setting on this screen goes back to its default. Your hosts, keys, scripts and '
          'alert rules are not affected.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('settings.reset.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('settings.reset.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.resetToDefaults();
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: const ValueKey('settings.status'),
        leftAccent: OmniColors.green,
        child: Row(
          children: [
            Expanded(child: Text(vm.status!, style: const TextStyle(fontSize: 12))),
            IconButton(
              key: const ValueKey('settings.status.dismiss'),
              icon: const Icon(Icons.close, size: 16),
              onPressed: vm.dismissStatus,
            ),
          ],
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.settingKey,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String settingKey;
  final String title;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: ValueKey('settings.$settingKey'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
      value: value,
      // A dependent switch is disabled rather than hidden, so its existence and its precondition
      // stay visible instead of the row vanishing when the parent is turned off.
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.settingKey,
    required this.title,
    required this.value,
    required this.limits,
    required this.step,
    required this.onChanged,
    this.suffix = '',
    this.subtitle,
  });

  final String settingKey;
  final String title;
  final String? subtitle;
  final int value;
  final PreferenceRange limits;
  final int step;
  final String suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13)),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('settings.$settingKey.down'),
            icon: const Icon(Icons.remove, size: 18),
            // Disabled at the bound rather than silently doing nothing, so the limit is visible.
            onPressed: value <= limits.min
                ? null
                : () => onChanged((value - step).clamp(limits.min, limits.max)),
          ),
          SizedBox(
            width: 72,
            child: Text(
              '$value$suffix',
              key: ValueKey('settings.$settingKey.value'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          IconButton(
            key: ValueKey('settings.$settingKey.up'),
            icon: const Icon(Icons.add, size: 18),
            onPressed: value >= limits.max
                ? null
                : () => onChanged((value + step).clamp(limits.min, limits.max)),
          ),
        ],
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.settingKey,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String settingKey;
  final String title;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<T>(
        key: ValueKey('settings.$settingKey'),
        initialValue: value,
        decoration: omniInputDecoration(context, labelText: title),
        items: [
          for (final entry in options.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
