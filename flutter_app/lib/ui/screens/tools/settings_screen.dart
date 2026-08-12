import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../domain/app_lock_timeout_policy.dart';
import '../../../domain/app_preferences.dart';
import '../../../domain/platform_settings.dart';
import '../../widgets/sudo_auth_dialog.dart';
import '../../theme/colors.dart';
import '../../view_model/app_lock_controller.dart';
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
  /// The in-progress edit of the lock timeout, or null to derive it from the saved value.
  ///
  /// Held here rather than computed from the preference because a half-typed custom duration has no
  /// representation as a number. Deleting the `0` from `10` momentarily gives `1`, which *is* a
  /// preset — recomputing from the value alone would snap to that preset and take the text field
  /// away mid-edit, which is the Kotlin bug fixed in its PR #62.
  AppLockTimeoutDraft? _lockTimeout;

  /// Owned by the State, not rebuilt per frame: a controller created inside `build` throws away the
  /// selection on every keystroke, so the caret jumps to the start as you type.
  final _lockCustomValue = TextEditingController();

  AppLockTimeoutDraft _lockTimeoutFor(int savedMs) {
    final local = _lockTimeout;
    // A local edit is only still the user's if it agrees with the draft it produced. Once Discard
    // or Reset moves the saved value elsewhere, the edit is stale and the value wins.
    if (local != null && local.timeoutMs == savedMs) return local;
    return AppLockTimeoutDraft.fromTimeout(savedMs);
  }

  bool _lockTimeoutValid(AppPreferences draft) =>
      !draft.appLockEnabled || _lockTimeoutFor(draft.appLockTimeoutMs).isValid;

  void _applyLockTimeout(SettingsViewModel vm, AppLockTimeoutDraft updated) {
    setState(() => _lockTimeout = updated);
    vm.update((p) => p.copyWith(appLockTimeoutMs: updated.timeoutMs));
  }

  @override
  void dispose() {
    _lockCustomValue.dispose();
    super.dispose();
  }

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
    // True where the lock controller is absent (tests, and any build without one): the option then
    // behaves exactly as it did before this check existed.
    final biometricsAvailable = context.watch<AppLockController?>()?.biometricsAvailable ?? true;

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
            _Choice<bool?>(
              settingKey: 'darkMode',
              title: 'Theme',
              value: draft.darkMode,
              options: const {null: 'System Default', true: 'Dark Theme', false: 'Light Theme'},
              onChanged: (v) => vm.update((p) => p.copyWith(darkMode: v, clearDarkMode: v == null)),
            ),
            _Switch(
              settingKey: 'amoled',
              title: 'AMOLED black',
              subtitle: 'True black backgrounds, which save power on OLED screens',
              value: draft.amoled,
              // Kotlin: `enabled = draftDark != false`. The toggle is available whenever the
              // theme is Dark or System Default — the user should be able to pre-enable AMOLED
              // for when night mode turns on, even if the device is currently in light mode.
              enabled: draft.darkMode != false,
              onChanged: (v) => vm.update((p) => p.copyWith(amoled: v)),
            ),
            _Switch(
              settingKey: 'accessibility',
              title: 'High contrast mode',
              subtitle: 'Stronger colors and borders for better visibility',
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
              options: {for (final system in MeasurementSystem.values) system: system.label},
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
                onChanged: (v) => vm.update((p) => p.copyWith(batterySaverThresholdPercent: v)),
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
              options: terminalThemes,
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
              subtitle:
                  'Highlighting a large file blocks the frame long enough to look like a hang',
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
              // Says which of the two reasons it is off, because "enable the lock first" and "this
              // device has nothing enrolled" need different actions from the user.
              subtitle: biometricsAvailable
                  ? null
                  : 'No fingerprint or device credential is enrolled on this device',
              value: draft.useBiometrics && biometricsAvailable,
              enabled: draft.appLockEnabled && biometricsAvailable,
              onChanged: (v) => vm.update((p) => p.copyWith(useBiometrics: v)),
            ),
            _lockTimeoutSection(context, vm, draft),
            _Switch(
              settingKey: 'blockScreenshots',
              title: 'Block screenshots',
              // Accurate on both platforms rather than flattering on one: Android blocks
              // screenshots outright, iOS cannot and only covers the app-switcher preview.
              subtitle:
                  'Hides the app in the recent-apps preview. Screenshots are blocked on '
                  'Android; iOS does not allow that.',
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
                  // A half-typed custom duration is the one thing here that can be *invalid*
                  // rather than merely unusual, and saving it would silently keep the previous
                  // interval while the screen showed the new one.
                  onPressed: vm.isDirty && _lockTimeoutValid(draft)
                      ? () => _save(context, vm)
                      : null,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// How long OmniTerm may be off screen before it asks for the PIN again, plus changing that PIN.
  ///
  /// Without this the interval was fixed at its 30-second default with no way to reach it, and a
  /// PIN once set could only be changed by turning the lock off — which deletes it. Both are
  /// available in the Android app, so both belong here.
  Widget _lockTimeoutSection(BuildContext context, SettingsViewModel vm, AppPreferences draft) {
    if (!draft.appLockEnabled) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final timeout = _lockTimeoutFor(draft.appLockTimeoutMs);
    final lock = context.watch<AppLockController?>();

    // The field shows what the draft holds, which is not always what was typed: `editCustomValue`
    // strips anything that is not a digit, and that filtering has to be visible in the field or the
    // rejected characters appear to have been accepted.
    if (_lockCustomValue.text != timeout.customValue) {
      _lockCustomValue.value = TextEditingValue(
        text: timeout.customValue,
        selection: TextSelection.collapsed(offset: timeout.customValue.length),
      );
    }

    return Padding(
      key: const ValueKey('settings.lockTimeout'),
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Lock when returning after', style: TextStyle(fontSize: 13)),
          Text(
            // Saying exactly when the countdown starts, because "after" alone invites the guess
            // that it means idle time inside the app.
            'The countdown starts once OmniTerm is no longer visible. Rotating the screen does not '
            'start it; a full restart always locks.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (label, ms) in appLockTimeoutPresets)
                ChoiceChip(
                  key: ValueKey('settings.lockTimeout.$ms'),
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: !timeout.customSelected && timeout.timeoutMs == ms,
                  onSelected: (_) => _applyLockTimeout(vm, timeout.selectPreset(ms)),
                ),
              ChoiceChip(
                key: const ValueKey('settings.lockTimeout.custom'),
                label: const Text('Custom', style: TextStyle(fontSize: 12)),
                selected: timeout.customSelected,
                onSelected: (_) => _applyLockTimeout(vm, timeout.selectCustom()),
              ),
            ],
          ),
          if (timeout.customSelected) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('settings.lockTimeout.value'),
                    controller: _lockCustomValue,
                    keyboardType: TextInputType.number,
                    decoration: omniInputDecoration(
                      context,
                      labelText: 'Custom duration',
                      errorText: timeout.isValid ? null : 'Choose a duration up to 24 hours',
                    ),
                    onChanged: (input) => _applyLockTimeout(vm, timeout.editCustomValue(input)),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  key: const ValueKey('settings.lockTimeout.unit'),
                  value: timeout.customUnit,
                  items: [
                    for (final unit in appLockTimeoutUnits)
                      DropdownMenuItem(value: unit, child: Text(unit)),
                  ],
                  onChanged: (unit) =>
                      unit == null ? null : _applyLockTimeout(vm, timeout.selectCustomUnit(unit)),
                ),
              ],
            ),
          ],
          if (lock != null && lock.isConfigured)
            TextButton(
              key: const ValueKey('settings.changePin'),
              onPressed: () => _changePin(context, lock),
              child: const Text('Change PIN', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _changePin(BuildContext context, AppLockController lock) async {
    final pin = await _askForPin(context);
    // Cancelling leaves the existing PIN in place: a change that is abandoned half way must not be
    // a way to end up with no PIN behind a lock that still says it is on.
    if (pin != null) await lock.setPin(pin);
  }

  /// Saves, and makes the app-lock switch mean something.
  ///
  /// Turning the lock on has to collect a PIN: an "app lock" with nothing to unlock it is a switch
  /// that reports protection it is not providing, which is worse than no switch. Turning it off
  /// forgets the PIN rather than leaving a stale hash behind for the next time it is enabled.
  Future<void> _save(BuildContext context, SettingsViewModel vm) async {
    final lock = context.read<AppLockController?>();
    final wantsLock = vm.draft.appLockEnabled;
    final hadLock = vm.saved.appLockEnabled;

    // Turning App Lock off destroys the stored PIN and the biometric enrolment with it. Say so
    // before asking for the PIN, not after: authenticating first would collect the credential and
    // *then* reveal that passing the prompt is what deletes it. Kotlin orders it the same way
    // (`ui/ToolsScreen.kt:3903`).
    if (hadLock && !wantsLock) {
      final turnOff = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('settings.appLockOff.dialog'),
          title: const Text('Turn off App Lock?'),
          content: const Text(
            'This deletes your saved PIN and disables biometric unlock. '
            "You'll need to set a new PIN to turn App Lock back on.",
          ),
          actions: [
            TextButton(
              key: const ValueKey('settings.appLockOff.cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('settings.appLockOff.confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Turn off', style: TextStyle(color: OmniColors.red)),
            ),
          ],
        ),
      );
      if (turnOff != true) return;
      if (!context.mounted) return;
    }

    // Saving is gated behind the PIN whenever one exists, matching Kotlin
    // (`ui/ToolsScreen.kt:3902`). Without it, anyone holding a briefly-unlocked phone could turn
    // the app lock *off* — which clears the stored PIN outright below — along with screenshot
    // blocking and sensitive-info masking, none of which should be reachable without proving you
    // can already pass the lock.
    if (lock != null && lock.hasStoredPin) {
      final confirmed = await requestSudoAuth(
        context,
        lock,
        title: 'Authenticate to save settings',
      );
      if (!confirmed) return;
      if (!context.mounted) return;
    }

    if (lock != null && wantsLock && !lock.isConfigured) {
      final pin = await _askForPin(context);
      if (pin == null) {
        // Cancelling must not leave the switch on and unbacked; put it back where it was.
        vm.update((p) => p.copyWith(appLockEnabled: false, useBiometrics: false));
        return;
      }
      await lock.setPin(pin);
    }

    await vm.save();
    if (lock == null) return;
    if (!wantsLock && hadLock) {
      await lock.clearPin();
    } else {
      await lock.refresh();
    }
  }

  Future<String?> _askForPin(BuildContext context) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _PinDialog(),
  );

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
              tooltip: 'Dismiss',
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
    // Settings the running platform cannot honour are shown, disabled, saying why — not hidden. A
    // row that vanishes reads as the app having forgotten the setting, and the value is still
    // carried in backups taken on a platform where it does work.
    final unavailable = settingUnavailableReason(settingKey, isIOS: !kIsWeb && Platform.isIOS);
    final detail = unavailable ?? subtitle;
    return SwitchListTile(
      key: ValueKey('settings.$settingKey'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: detail == null
          ? null
          : Text(
              detail,
              style: TextStyle(
                fontSize: 11,
                color: unavailable == null
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : OmniColors.amber,
              ),
            ),
      value: value,
      // A dependent switch is disabled rather than hidden, so its existence and its precondition
      // stay visible instead of the row vanishing when the parent is turned off.
      onChanged: enabled && unavailable == null ? onChanged : null,
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
                  Text(subtitle!, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Decrease',
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
            tooltip: 'Increase',
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

/// Collects and confirms a new app-lock PIN.
class _PinDialog extends StatefulWidget {
  const _PinDialog();

  /// Four is the shortest length that is not trivially shoulder-surfed in one glance, and matches
  /// what the Kotlin app accepted so an upgrading user is not forced to change theirs.
  static const minLength = 4;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final TextEditingController _first = TextEditingController();
  final TextEditingController _second = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _first.text;
    setState(() {
      // Confirmed rather than taken on the first entry: there is no PIN recovery, so a typo here
      // locks the user out of their own hosts permanently.
      _error = pin.length < _PinDialog.minLength
          ? 'Use at least ${_PinDialog.minLength} digits'
          : (pin != _second.text ? 'The two entries do not match' : null);
    });
    if (_error == null) Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('settings.pin.dialog'),
    // An AlertDialog's content does not scroll unless it asks to. This one holds a three-line
    // warning, two fields and — when the entries disagree — an error line, which overflows a small
    // phone in landscape at 200% text by 39px, hiding the very message explaining what went wrong.
    scrollable: true,
    title: const Text('Set an app PIN'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'There is no PIN recovery. If you forget it, the only way back in is to reinstall, '
          'which clears your saved hosts.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        _pinField(_first, 'PIN', const ValueKey('settings.pin.first')),
        const SizedBox(height: 8),
        _pinField(_second, 'Confirm PIN', const ValueKey('settings.pin.second')),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _error!,
              key: const ValueKey('settings.pin.error'),
              style: const TextStyle(fontSize: 12, color: OmniColors.red),
            ),
          ),
      ],
    ),
    actions: [
      TextButton(
        key: const ValueKey('settings.pin.cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('settings.pin.confirm'),
        onPressed: _submit,
        child: const Text('Set PIN'),
      ),
    ],
  );

  Widget _pinField(TextEditingController controller, String label, Key key) => TextField(
    key: key,
    controller: controller,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    maxLength: 12,
    decoration: InputDecoration(labelText: label, counterText: ''),
  );
}
