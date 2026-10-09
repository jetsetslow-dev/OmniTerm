import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../domain/app_lock_timeout_policy.dart';
import '../../../domain/app_preferences.dart';
import '../../navigation.dart';
import '../../theme/typography.dart';
import '../../theme/text_scaling.dart';
import '../../../domain/platform_settings.dart';
import '../../widgets/sudo_auth_dialog.dart';
import '../../theme/colors.dart';
import '../../view_model/app_lock_controller.dart';
import '../../view_model/settings_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/popup_scroll_behavior.dart';

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
  bool _biometricBusy = false;
  bool _saving = false;
  bool _persisting = false;
  // A successful preferences write can precede a failed PIN cleanup. Keep that remaining
  // operation across Retry save, even though the saved lock-enabled preference is already false.
  bool _pendingPinRemoval = false;
  String? _saveError;
  String? _biometricMessage;

  /// The in-progress edit of the lock timeout, or null to derive it from the saved value.
  ///
  /// Held here rather than computed from the preference because a half-typed custom duration has no
  /// representation as a number. Deleting the `0` from `10` momentarily gives `1`, which *is* a
  /// preset — recomputing from the value alone would snap to that preset and take the text field
  /// away mid-edit, which is the Kotlin bug fixed in its PR #62.
  AppLockTimeoutDraft? _lockTimeout;
  int _seenDraftRevision = 0;

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
    vm.setFieldValidity('appLockTimeout', !vm.draft.appLockEnabled || updated.isValid);
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
    if (_seenDraftRevision != vm.draftRevision) {
      _seenDraftRevision = vm.draftRevision;
      _lockTimeout = null;
    }
    // True where the lock controller is absent (tests, and any build without one): the option then
    // behaves exactly as it did before this check existed.
    final biometricsAvailable = context.watch<AppLockController?>()?.biometricsAvailable ?? true;

    return DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 16, height: 1.5, letterSpacing: .5),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('settings.back'),
                  tooltip: 'Back',
                  onPressed: () => context.read<NavigationController>().navigateTo(Screen.tools),
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    'App settings',
                    style: TextStyle(
                      fontFamily: OmniFonts.display,
                      fontSize: 18,
                      height: 24 / 18,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: const PopupScrollBehavior(popupsOnly: false),
                      child: ListView(
                        key: const ValueKey('settings.list'),
                        padding: EdgeInsets.zero,
                        children: [
                          if (vm.status != null && !_saving && _saveError == null)
                            _StatusCard(vm: vm),
                          if (_saveError != null)
                            Text(
                              _saveError!,
                              key: const ValueKey('settings.save.error'),
                              style: const TextStyle(color: OmniColors.red),
                            ),
                          if (_persisting)
                            const LinearProgressIndicator(key: ValueKey('settings.save.progress')),
                          _SettingsCard(
                            title: 'Security gate app lock',
                            subtitle: 'Require a PIN or biometrics at startup and after time away.',
                            accent: OmniColors.cyan,
                            children: [
                              _Switch(
                                settingKey: 'appLockEnabled',
                                title: 'Require PIN to unlock',
                                value: draft.appLockEnabled,
                                onChanged: (v) => _setAppLock(context, vm, v),
                              ),
                              if (draft.appLockEnabled) ...[
                                _Switch(
                                  settingKey: 'biometrics',
                                  title: 'Unlock with biometrics',
                                  subtitle: _biometricBusy
                                      ? 'Waiting for biometric verification…'
                                      : biometricsAvailable
                                      ? null
                                      : 'Set up a strong biometric in your phone settings first',
                                  value: draft.useBiometrics && biometricsAvailable,
                                  enabled: biometricsAvailable && !_biometricBusy,
                                  onChanged: (v) => _setBiometrics(context, vm, v),
                                ),
                                if (_biometricBusy) const LinearProgressIndicator(),
                                if (_biometricMessage != null)
                                  Text(
                                    _biometricMessage!,
                                    key: const ValueKey('settings.biometricMessage'),
                                  ),
                                TextButton(
                                  key: const ValueKey('settings.changePin'),
                                  onPressed: () {
                                    final lock = context.read<AppLockController?>();
                                    if (lock != null) _changePin(context, lock);
                                  },
                                  child: const Text('Change PIN'),
                                ),
                                _lockTimeoutSection(context, vm, draft),
                              ],
                              _Switch(
                                settingKey: 'blockScreenshots',
                                title: 'Block screenshots',
                                subtitle:
                                    'Hides terminals and credentials from screenshots and the app switcher.',
                                value: draft.blockScreenshots,
                                onChanged: (v) => vm.update((p) => p.copyWith(blockScreenshots: v)),
                              ),
                              const SizedBox(height: 12),
                              _Switch(
                                settingKey: 'hideSensitiveInfo',
                                title: 'Hide sensitive info',
                                subtitle:
                                    'Replaces IPs/hostnames with host names across the app — safe for screenshots and screen shares.',
                                value: draft.hideSensitiveInfo,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(hideSensitiveInfo: v)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _SettingsCard(
                            title: 'Display Behavior',
                            subtitle: 'App appearance, refresh cadence, and screen power.',
                            accent: OmniColors.green,
                            gap: 10,
                            headerGap: 0,
                            children: [
                              _SettingRow(
                                title: 'Measurement system',
                                subtitle:
                                    'Applies to temperatures and other physical measurements throughout the app.',
                                control: _SettingChips<MeasurementSystem>(
                                  settingKey: 'measurementSystem',
                                  value: draft.measurementSystem,
                                  spacing: 6,
                                  options: {
                                    MeasurementSystem.metric: 'Metric',
                                    MeasurementSystem.imperial: 'Imperial',
                                  },
                                  onChanged: (v) =>
                                      vm.update((p) => p.copyWith(measurementSystem: v)),
                                ),
                              ),
                              _Switch(
                                settingKey: 'keepScreenOn',
                                title: 'Keep device screen always on',
                                value: draft.keepScreenOn,
                                onChanged: (v) => vm.update((p) => p.copyWith(keepScreenOn: v)),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _Switch(
                                    settingKey: 'batterySaverEnabled',
                                    title: 'Low-battery saver',
                                    subtitle:
                                        'Below the threshold (unplugged): turn off keep-screen-on, pause '
                                        'auto-refresh, and park tmux terminals resumably. Resumes on '
                                        'charge, recovery, or pull-to-refresh.',
                                    subtitleSize: 10,
                                    value: draft.batterySaverEnabled,
                                    onChanged: (v) =>
                                        vm.update((p) => p.copyWith(batterySaverEnabled: v)),
                                  ),
                                  if (draft.batterySaverEnabled) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      'Engage below: ${draft.batterySaverThresholdPercent}%',
                                      style: const TextStyle(fontSize: 12, height: 24 / 12),
                                    ),
                                    _SettingChips<int>(
                                      settingKey: 'batterySaverThreshold',
                                      value: draft.batterySaverThresholdPercent,
                                      fontSize: 12,
                                      options: const {10: '10%', 15: '15%', 20: '20%', 30: '30%'},
                                      onChanged: (v) => vm.update(
                                        (p) => p.copyWith(batterySaverThresholdPercent: v),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              _SettingRow(
                                title: 'Auto-refresh interval',
                                subtitle: 'How often host metrics refresh',
                                control: _SettingMenu<int>(
                                  settingKey: 'telemetryInterval',
                                  label: '${draft.telemetryIntervalSeconds}s',
                                  options: const {
                                    5: '5s',
                                    10: '10s',
                                    15: '15s',
                                    30: '30s',
                                    60: '60s',
                                    120: '120s',
                                  },
                                  onChanged: (v) =>
                                      vm.update((p) => p.copyWith(telemetryIntervalSeconds: v)),
                                ),
                              ),
                              _SettingRow(
                                title: 'Theme App Appearance',
                                subtitle: 'Use system or override',
                                control: _SettingMenu<bool?>(
                                  settingKey: 'darkMode',
                                  label: switch (draft.darkMode) {
                                    true => 'Dark',
                                    false => 'Light',
                                    null => 'System',
                                  },
                                  options: const {
                                    null: 'System Default',
                                    true: 'Dark Theme',
                                    false: 'Light Theme',
                                  },
                                  onChanged: (v) => vm.update(
                                    (p) => p.copyWith(darkMode: v, clearDarkMode: v == null),
                                  ),
                                ),
                              ),
                              _Switch(
                                settingKey: 'amoled',
                                title: 'AMOLED black',
                                subtitle:
                                    'Pure-black surfaces in dark mode to save power on OLED screens. No effect in Light or High-contrast mode.',
                                subtitleSize: 10,
                                value: draft.amoled,
                                enabled: draft.darkMode != false,
                                onChanged: (v) => vm.update((p) => p.copyWith(amoled: v)),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Editor syntax highlighting',
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  _settingDetail(
                                    context,
                                    'Max file size to colourise in the code editor (SFTP files, Compose YAML). '
                                    'Lower it if editing large files feels slow; "Off" disables highlighting.',
                                  ),
                                  const SizedBox(height: 6),
                                  _SettingChips<int>(
                                    settingKey: 'editorHighlightLimit',
                                    value: draft.editorHighlightLimitChars,
                                    options: const {
                                      0: 'Off',
                                      50000: '50 KB',
                                      100000: '100 KB',
                                      200000: 'Max',
                                    },
                                    onChanged: (v) =>
                                        vm.update((p) => p.copyWith(editorHighlightLimitChars: v)),
                                  ),
                                ],
                              ),
                              _Switch(
                                settingKey: 'accessibility',
                                title: 'High-contrast mode',
                                subtitle:
                                    'Stronger colors and borders for better readability. Applies on top of your Dark/Light theme.',
                                subtitleSize: 10,
                                value: draft.accessibility,
                                onChanged: (v) => vm.update((p) => p.copyWith(accessibility: v)),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Text size',
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  _settingDetail(context, 'Scales text across all screens.'),
                                  const SizedBox(height: 6),
                                  _SettingChips<int>(
                                    settingKey: 'textScale',
                                    value: draft.textScalePercent,
                                    options: const {80: 'Small', 92: 'Default', 110: 'Large'},
                                    onChanged: (v) =>
                                        vm.update((p) => p.copyWith(textScalePercent: v)),
                                  ),
                                ],
                              ),
                              _Switch(
                                settingKey: 'backgroundKeepAlive',
                                title: 'Keep sessions alive in background',
                                subtitle: 'Maintain active SSH/SFTP sessions when app is minimized',
                                subtitleSize: 10,
                                value: draft.backgroundKeepAlive,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(backgroundKeepAlive: v)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _SettingsCard(
                            title: 'Metrics Data Pruning',
                            subtitle: 'Pruning metric history logs prevents database overflow.',
                            accent: OmniColors.amber,
                            children: [
                              Text('Retention Window: ${draft.metricsRetentionDays} days'),
                              _SettingSlider(
                                settingKey: 'metricsRetention',
                                value: draft.metricsRetentionDays,
                                min: 1,
                                max: 30,
                                divisions: 29,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(metricsRetentionDays: v)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _SettingsCard(
                            title: 'Terminal',
                            subtitle: 'Persistent terminal display preferences.',
                            accent: OmniColors.purple,
                            gap: 10,
                            children: [
                              Text(
                                'Font size: ${draft.terminalFontSize}sp',
                                style: const TextStyle(fontSize: 12, height: 24 / 12),
                              ),
                              _SettingSlider(
                                settingKey: 'terminalFontSize',
                                value: draft.terminalFontSize,
                                min: 8,
                                max: 28,
                                divisions: 20,
                                onChanged: (v) => vm.update((p) => p.copyWith(terminalFontSize: v)),
                              ),
                              const Text(
                                'Theme',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 24 / 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              _SettingChips<String>(
                                settingKey: 'terminalTheme',
                                value: draft.terminalTheme,
                                options: terminalThemes,
                                fontSize: 11,
                                onChanged: (v) => vm.update((p) => p.copyWith(terminalTheme: v)),
                              ),
                              Text(
                                'Scrollback: ${draft.terminalScrollbackLimit ~/ 1000}k lines',
                                style: const TextStyle(fontSize: 12, height: 24 / 12),
                              ),
                              _SettingSlider(
                                settingKey: 'terminalScrollback',
                                value: draft.terminalScrollbackLimit,
                                min: 1000,
                                max: 50000,
                                divisions: 49,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(terminalScrollbackLimit: v)),
                              ),
                              _settingDetail(
                                context,
                                'Applies to new terminal sessions. Existing sessions keep their current buffer.',
                                size: 10,
                              ),
                              const SizedBox(height: 8),
                              _Switch(
                                settingKey: 'smartSwipe',
                                title: 'Smart swipe input',
                                trailingGap: 12,
                                subtitle:
                                    "Lets gesture keyboards correct each swiped word before it's sent. "
                                    'Turn off to disable swipe-typing and accept strict, literal '
                                    'keystrokes like a password field (no autocorrect or suggestions).',
                                value: draft.smartSwipeInput,
                                onChanged: (v) => vm.update((p) => p.copyWith(smartSwipeInput: v)),
                              ),
                              _Switch(
                                settingKey: 'tmuxControlMode',
                                title: 'tmux control mode (experimental)',
                                trailingGap: 12,
                                subtitle:
                                    "Persistent sessions attach with tmux's control protocol "
                                    '(what iTerm2 uses): every output byte is streamed, so '
                                    'scroll history is always complete — nothing is skipped '
                                    "while you're not watching. Split panes made inside tmux "
                                    "aren't rendered. Applies to newly opened sessions.",
                                value: draft.tmuxControlMode,
                                onChanged: (v) => vm.update((p) => p.copyWith(tmuxControlMode: v)),
                              ),
                              _Switch(
                                settingKey: 'linkDetection',
                                title: 'Tap-to-open links',
                                trailingGap: 12,
                                subtitle:
                                    'Detect URLs in terminal output (including lines wrapped across '
                                    'rows) and open them on tap. Best-effort pattern matching — '
                                    'turn off if taps misfire on unusual output.',
                                value: draft.terminalLinkDetection,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(terminalLinkDetection: v)),
                              ),
                              _Switch(
                                settingKey: 'linkOpenInApp',
                                title: 'Open links in-app',
                                trailingGap: 12,
                                subtitle:
                                    'Tapped links open in an in-app browser tab (back returns '
                                    'straight to the terminal). Turn off to hand links to your '
                                    'external browser app instead.',
                                value: draft.linkOpenInApp,
                                enabled: draft.terminalLinkDetection,
                                onChanged: (v) => vm.update((p) => p.copyWith(linkOpenInApp: v)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _SettingsCard(
                            title: 'Alert History',
                            subtitle:
                                'Keep the newest acknowledged, muted, and resolved incidents per host.',
                            accent: OmniColors.red,
                            children: [
                              Text('History entries per host: ${draft.alertHistoryLimit}'),
                              _SettingSlider(
                                settingKey: 'alertHistoryLimit',
                                value: draft.alertHistoryLimit,
                                min: 10,
                                max: 100,
                                divisions: 9,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(alertHistoryLimit: v)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _SettingsCard(
                            title: 'SFTP Transfer Warnings',
                            subtitle: 'Warn before large multi-file uploads or downloads.',
                            accent: OmniColors.cyan,
                            gap: 10,
                            children: [
                              _SettingNumber(
                                key: ValueKey('sftpWarnFileCount.${vm.draftRevision}'),
                                settingKey: 'sftpWarnFileCount',
                                onValid: (valid) => vm.setFieldValidity('sftpWarnFileCount', valid),
                                label: 'Warn at file count',
                                value: draft.sftpWarnFileCount,
                                digits: 5,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(sftpWarnFileCount: v)),
                              ),
                              _SettingNumber(
                                key: ValueKey('sftpWarnGigabytes.${vm.draftRevision}'),
                                settingKey: 'sftpWarnGigabytes',
                                onValid: (valid) => vm.setFieldValidity('sftpWarnGigabytes', valid),
                                label: 'Warn at total download size (GB)',
                                value: draft.sftpWarnGigabytes,
                                digits: 4,
                                onChanged: (v) =>
                                    vm.update((p) => p.copyWith(sftpWarnGigabytes: v)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('settings.revert'),
                            style: _outlinedSettingsButton(context),
                            onPressed: vm.isDirty && !_saving ? vm.revert : null,
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('settings.save'),
                            style: _filledSettingsButton(context),
                            onPressed:
                                (vm.isDirty || _saveError != null) &&
                                    vm.isValid &&
                                    !_saving &&
                                    _lockTimeoutValid(draft)
                                ? () => _save(context, vm)
                                : null,
                            child: Text(
                              _saving
                                  ? 'Saving…'
                                  : _saveError != null
                                  ? 'Retry save'
                                  : 'Save changes',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setBiometrics(BuildContext context, SettingsViewModel vm, bool enabled) async {
    final lock = context.read<AppLockController?>();
    if (!enabled || lock == null) {
      vm.update((p) => p.copyWith(useBiometrics: enabled));
      return;
    }
    if (_biometricBusy) return;
    setState(() {
      _biometricBusy = true;
      _biometricMessage = null;
    });
    final verified = await lock.verifyBiometricsForSetup();
    if (!mounted) return;
    setState(() {
      _biometricBusy = false;
      _biometricMessage = verified ? null : (lock.biometricError ?? 'Biometric setup cancelled.');
    });
    if (verified) vm.update((p) => p.copyWith(useBiometrics: true));
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
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Lock when returning after', style: TextStyle(fontSize: 13, height: 24 / 13)),
          Text(
            // Saying exactly when the countdown starts, because "after" alone invites the guess
            // that it means idle time inside the app.
            "The countdown starts once OmniTerm is no longer visible. Rotation doesn't start it; "
            "a full process restart always locks.",
            style: TextStyle(fontSize: 11, height: 24 / 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 0,
            children: [
              for (final (label, ms) in appLockTimeoutPresets)
                FilterChip(
                  showCheckmark: false,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  backgroundColor: Colors.transparent,
                  key: ValueKey('settings.lockTimeout.$ms'),
                  label: Text(label, style: const TextStyle(fontSize: 12, height: 20 / 12)),
                  selected: !timeout.customSelected && timeout.timeoutMs == ms,
                  onSelected: (_) => _applyLockTimeout(vm, timeout.selectPreset(ms)),
                ),
              FilterChip(
                showCheckmark: false,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                backgroundColor: Colors.transparent,
                key: const ValueKey('settings.lockTimeout.custom'),
                label: const Text('Custom', style: TextStyle(fontSize: 12, height: 20 / 12)),
                selected: timeout.customSelected,
                onSelected: (_) => _applyLockTimeout(vm, timeout.selectCustom()),
              ),
            ],
          ),
          if (timeout.customSelected) ...[
            const SizedBox(height: 6),
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
                _SettingMenu<String>(
                  settingKey: 'lockTimeout.unit',
                  label: timeout.customUnit,
                  options: {for (final unit in appLockTimeoutUnits) unit: unit},
                  onChanged: (unit) => _applyLockTimeout(vm, timeout.selectCustomUnit(unit)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _setAppLock(BuildContext context, SettingsViewModel vm, bool enabled) async {
    final lock = context.read<AppLockController?>();
    vm.setFieldValidity(
      'appLockTimeout',
      !enabled || _lockTimeoutFor(vm.draft.appLockTimeoutMs).isValid,
    );
    if (enabled && lock != null && !lock.hasStoredPin) {
      await _changePin(context, lock);
    } else {
      vm.update(
        (p) =>
            p.copyWith(appLockEnabled: enabled, useBiometrics: enabled ? p.useBiometrics : false),
      );
    }
  }

  Future<void> _changePin(BuildContext context, AppLockController lock) async {
    final vm = context.read<SettingsViewModel>();
    await showDialog<void>(
      context: context,
      builder: (_) => _PinDialog(
        onSave: (pin) async {
          await lock.setPin(pin);
          vm.pinConfigured();
        },
      ),
    );
  }

  /// Saves, and makes the app-lock switch mean something.
  ///
  /// Turning the lock on has to collect a PIN: an "app lock" with nothing to unlock it is a switch
  /// that reports protection it is not providing, which is worse than no switch. Turning it off
  /// forgets the PIN rather than leaving a stale hash behind for the next time it is enabled.
  Future<void> _save(BuildContext context, SettingsViewModel vm) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await _saveConfirmed(context, vm);
    } catch (error) {
      if (mounted) {
        setState(() => _saveError = 'Could not save settings: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _persisting = false;
        });
      }
    }
  }

  Future<void> _saveConfirmed(BuildContext context, SettingsViewModel vm) async {
    final lock = context.read<AppLockController?>();
    final wantsLock = vm.draft.appLockEnabled;
    final hadLock = vm.saved.appLockEnabled;
    final removingPin = !wantsLock && (hadLock || _pendingPinRemoval);

    // Turning App Lock off destroys the stored PIN and the biometric enrolment with it. Say so
    // before asking for the PIN, not after: authenticating first would collect the credential and
    // *then* reveal that passing the prompt is what deletes it. Kotlin orders it the same way
    // (`ui/ToolsScreen.kt:3903`).
    if (removingPin) {
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

    _pendingPinRemoval = removingPin;
    if (mounted) setState(() => _persisting = true);
    await vm.save();
    if (lock == null) return;
    if (removingPin) {
      await lock.clearPin();
      _pendingPinRemoval = false;
    } else {
      await lock.refresh();
    }
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
            Expanded(
              child: Text(vm.status!, style: const TextStyle(fontSize: 12, height: 24 / 12)),
            ),
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
    this.subtitleSize = 11,
    this.trailingGap = 0,
  });

  final String settingKey;
  final String title;
  final String? subtitle;
  final bool value;
  final bool enabled;
  final double subtitleSize;
  final double trailingGap;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Settings the running platform cannot honour are shown, disabled, saying why — not hidden. A
    // row that vanishes reads as the app having forgotten the setting, and the value is still
    // carried in backups taken on a platform where it does work.
    final unavailable = settingUnavailableReason(settingKey, isIOS: !kIsWeb && Platform.isIOS);
    final detail = unavailable ?? subtitle;
    return _SettingRow(
      title: title,
      subtitle: detail,
      subtitleSize: subtitleSize,
      trailingGap: trailingGap,
      control: Switch(
        padding: EdgeInsets.zero,
        key: ValueKey('settings.$settingKey'),
        value: value,
        onChanged: enabled && unavailable == null ? onChanged : null,
      ),
    );
  }
}

/// Kotlin's single-field PIN setup; completion waits for persistence.
class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.onSave});
  final Future<void> Function(String pin) onSave;
  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!RegExp(r'^\d{4,8}$').hasMatch(_pin.text)) {
      setState(() => _error = 'Enter a PIN with 4–8 digits.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(_pin.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save PIN: $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: _popupTextScaler(context)),
    child: PopScope(
      canPop: !_busy,
      child: AlertDialog(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 560),
        key: const ValueKey('settings.pin.dialog'),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        scrollable: true,
        title: const Text('Configure Security PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('settings.pin.first'),
              controller: _pin,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'PIN (4-8 digits)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                key: const ValueKey('settings.pin.error'),
                style: const TextStyle(color: OmniColors.red),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('settings.pin.cancel'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('settings.pin.confirm'),
            style: _filledSettingsButton(context),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Saving…' : 'Save PIN'),
          ),
        ],
      ),
    ),
  );
}

// Material 3 1.4's disabled tokens differ from Flutter's defaults. These come from the
// Kotlin dependency's FilledButtonTokens and OutlinedButtonTokens, including the 10% outline.
ButtonStyle _filledSettingsButton(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    disabledBackgroundColor: scheme.onSurface.withValues(alpha: .1),
    disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: .38),
  );
}

ButtonStyle _outlinedSettingsButton(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return OutlinedButton.styleFrom(
    foregroundColor: scheme.onSurfaceVariant,
    disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: .38),
  ).copyWith(
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled)
            ? scheme.outlineVariant.withValues(alpha: .1)
            : scheme.outlineVariant,
      ),
    ),
  );
}

// Native Dialog/Popup windows retain the phone's scaling, independently of the app preset.
TextScaler _popupTextScaler(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return scaler is OmniTextScaler ? scaler.platform : scaler;
}

Widget _settingDetail(BuildContext context, String text, {double size = 11}) => Text(
  text,
  style: TextStyle(
    fontSize: size,
    height: 24 / size,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.children,
    this.gap = 0,
    this.headerGap,
  });
  final String title;
  final String subtitle;
  final Color accent;
  final List<Widget> children;
  final double gap;
  final double? headerGap;

  @override
  Widget build(BuildContext context) => OmniCard(
    key: ValueKey('settings.card.$title'),
    leftAccent: accent,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              height: 24 / 12,
              letterSpacing: 1.5,
            ),
          ),
          _settingDetail(context, subtitle),
          const SizedBox(height: 8),
          Divider(height: 1, thickness: 1, color: accent.withValues(alpha: .35)),
          SizedBox(height: 10 + (headerGap ?? gap)),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0 && gap > 0) SizedBox(height: gap),
            children[i],
          ],
        ],
      ),
    ),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    this.subtitle,
    required this.control,
    this.subtitleSize = 11,
    this.trailingGap = 0,
  });
  final String title;
  final String? subtitle;
  final Widget control;
  final double subtitleSize;
  final double trailingGap;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Padding(
          padding: EdgeInsets.only(right: trailingGap),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              if (subtitle != null) _settingDetail(context, subtitle!, size: subtitleSize),
            ],
          ),
        ),
      ),
      control,
    ],
  );
}

class _SettingChips<T> extends StatelessWidget {
  const _SettingChips({
    required this.settingKey,
    required this.value,
    required this.options,
    required this.onChanged,
    this.spacing = 8,
    this.fontSize = 14,
  });
  final String settingKey;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final double spacing;
  final double fontSize;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: spacing,
    children: [
      for (final entry in options.entries)
        FilterChip(
          showCheckmark: false,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: Colors.transparent,
          key: ValueKey('settings.$settingKey.${entry.key}'),
          label: Text(
            entry.value,
            style: TextStyle(fontSize: fontSize, height: 20 / fontSize),
          ),
          selected: value == entry.key,
          onSelected: (_) => onChanged(entry.key),
        ),
    ],
  );
}

// The menu transports an index, since null is a real theme choice and PopupMenuButton uses null
// for cancellation. Selecting System must clear a stored forced theme.
class _SettingMenu<T> extends StatefulWidget {
  const _SettingMenu({
    required this.settingKey,
    required this.label,
    required this.options,
    required this.onChanged,
  });
  final String settingKey;
  final String label;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  @override
  State<_SettingMenu<T>> createState() => _SettingMenuState<T>();
}

class _SettingMenuState<T> extends State<_SettingMenu<T>> {
  final _anchor = GlobalKey();
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    // Compose opens the popup in a platform window, outside the app's density override.
    // Keep Android accessibility scaling while removing only OmniTerm's text preset.
    final scaler = MediaQuery.textScalerOf(context);
    final popupScaler = scaler is OmniTextScaler ? scaler.platform : scaler;
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w500,
      letterSpacing: .1 * popupScaler.scale(14) / 14,
    );
    var width = 112.0;
    for (final option in options.values) {
      final painter = TextPainter(
        text: TextSpan(text: option, style: style),
        textDirection: Directionality.of(context),
        textScaler: popupScaler,
      )..layout();
      width = (painter.width + 24).clamp(width, 280);
      painter.dispose();
    }
    var contentHeight = 16.0;
    for (final option in options.values) {
      final painter = TextPainter(
        text: TextSpan(text: option, style: style),
        textDirection: Directionality.of(context),
        textScaler: popupScaler,
      )..layout(maxWidth: width - 24);
      contentHeight += painter.height.clamp(48, double.infinity);
      painter.dispose();
    }
    return Semantics(
      key: _anchor,
      expanded: _expanded,
      child: Tooltip(
        message: widget.label,
        child: InkWell(
          key: ValueKey('settings.${widget.settingKey}'),
          onTap: _expanded
              ? null
              : () async {
                  final overlay =
                      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
                  final anchor = _anchor.currentContext!.findRenderObject()! as RenderBox;
                  final direction = Directionality.of(context);
                  final padding = MediaQueryData.fromView(View.of(context)).padding;
                  final maxHeight = (overlay.size.height - padding.vertical - 96).clamp(
                    0.0,
                    double.infinity,
                  );
                  final height = contentHeight.clamp(0.0, maxHeight);
                  var lastPosition = RelativeRect.fill;
                  setState(() => _expanded = true);
                  try {
                    final selected = await showMenu<int>(
                      context: context,
                      // Compose uses intrinsic width and a 48dp window margin. When below does not
                      // fit, prefer above the anchor rather than covering the lower navigation bar.
                      constraints: BoxConstraints(
                        minWidth: width,
                        maxWidth: width,
                        maxHeight: maxHeight,
                      ),
                      menuPadding: const EdgeInsets.symmetric(vertical: 8),
                      positionBuilder: (_, constraints) {
                        if (!anchor.attached) return lastPosition;
                        final rect =
                            anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
                        final size = constraints.biggest;
                        final xCandidates = [
                          if (direction == TextDirection.ltr) rect.left else rect.right - width,
                          if (direction == TextDirection.ltr) rect.right - width else rect.left,
                          if (rect.center.dx < size.width / 2) 0.0 else size.width - width,
                        ];
                        final top = padding.top + 48;
                        final bottom = size.height - padding.bottom - 48;
                        final yCandidates = [
                          rect.bottom,
                          rect.top - height,
                          rect.top - height / 2,
                          if (rect.center.dy < size.height / 2) top else bottom - height,
                        ];
                        final x = xCandidates.firstWhere(
                          (x) => x >= 0 && x + width <= size.width,
                          orElse: () => xCandidates.last,
                        );
                        final y = yCandidates.firstWhere(
                          (y) => y >= top && y + height <= bottom,
                          orElse: () => yCandidates.last,
                        );
                        return lastPosition = RelativeRect.fromRect(
                          Rect.fromLTWH(x, y, width, height),
                          Offset.zero & size,
                        );
                      },
                      items: [
                        for (var i = 0; i < options.length; i++)
                          PopupMenuItem(
                            value: i,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: MediaQuery(
                              data: MediaQuery.of(context).copyWith(textScaler: popupScaler),
                              child: Text(options.values.elementAt(i), style: style),
                            ),
                          ),
                      ],
                    );
                    if (mounted && selected != null) {
                      widget.onChanged(options.keys.elementAt(selected));
                    }
                  } finally {
                    if (mounted) setState(() => _expanded = false);
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Text(
              widget.label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.settingKey,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });
  final String settingKey;
  final int value;
  final int min;
  final int max;
  final int divisions;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliderTheme(
      // Kotlin Material 3 uses the handle-and-gap slider, not Flutter's older round thumb.
      data: SliderTheme.of(context).copyWith(
        trackHeight: 16,
        trackShape: const GappedSliderTrackShape(),
        trackGap: 6,
        thumbShape: const HandleThumbShape(),
        thumbSize: WidgetStateProperty.resolveWith(
          (states) => Size(states.contains(WidgetState.pressed) ? 2 : 4, 44),
        ),
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.secondaryContainer,
        activeTickMarkColor: scheme.onPrimary,
        inactiveTickMarkColor: scheme.primary,
        tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
      ),
      child: Slider(
        key: ValueKey('settings.$settingKey'),
        padding: const EdgeInsets.symmetric(vertical: 2),
        value: value.clamp(min, max).toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: divisions,
        onChanged: (v) => onChanged(v.round()),
      ),
    );
  }
}

class _SettingNumber extends StatefulWidget {
  const _SettingNumber({
    super.key,
    required this.settingKey,
    required this.label,
    required this.value,
    required this.digits,
    required this.onChanged,
    required this.onValid,
  });
  final String settingKey;
  final String label;
  final int value;
  final int digits;
  final ValueChanged<int> onChanged;
  final ValueChanged<bool> onValid;
  @override
  State<_SettingNumber> createState() => _SettingNumberState();
}

class _SettingNumberState extends State<_SettingNumber> {
  late final _controller = TextEditingController(text: '${widget.value}');
  bool _valid = true;
  bool _editing = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SettingNumber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && widget.value != oldWidget.value) {
      _controller.text = '${widget.value}';
      _valid = true;
    }
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: ValueKey('settings.${widget.settingKey}'),
    controller: _controller,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(widget.digits),
    ],
    decoration: InputDecoration(
      labelText: widget.label,
      border: const OutlineInputBorder(),
      errorText: _valid ? null : 'Enter a positive number',
    ),
    onChanged: (text) {
      final parsed = int.tryParse(text);
      final valid = parsed != null;
      setState(() {
        _editing = true;
        _valid = valid;
      });
      widget.onValid(valid);
      if (valid) {
        // Kotlin retains the typed digits until Save, and clamps the persisted threshold.
        widget.onChanged(parsed.clamp(1, widget.settingKey == 'sftpWarnFileCount' ? 10000 : 9999));
      }
    },
  );
}
