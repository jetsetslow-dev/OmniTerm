/// App-lock background-timeout policy, ported from `ui/AppLockTimeoutPolicy.kt`.
library;

const defaultAppLockBackgroundTimeoutMs = 30 * 1000;
const maxAppLockBackgroundTimeoutMs = 24 * 60 * 60 * 1000;

/// The durations offered as one-tap presets; anything else counts as a custom value. Derived from
/// [appLockTimeoutPresets] so a chip can never be offered that this set does not recognise —
/// which would show the chip selected and the custom field open at the same time.
final _appLockTimeoutPresetValuesMs = {for (final (_, ms) in appLockTimeoutPresets) ms};

const _appLockUnits = <String, int>{
  'Seconds': 1000,
  'Minutes': 60 * 1000,
  'Hours': 3600 * 1000,
};

/// The units the screen offers, taken from the same map that parses them so a unit can never be
/// offered that [parseAppLockCustomDuration] would then reject.
List<String> get appLockTimeoutUnits => List.unmodifiable(_appLockUnits.keys);

/// The preset durations, as (label, milliseconds), in the Android app's own wording.
const appLockTimeoutPresets = <(String, int)>[
  ('Immediately', 0),
  ('30s', 30 * 1000),
  ('1 min', 60 * 1000),
  ('5 min', 300 * 1000),
];

int normalizeAppLockBackgroundTimeout(int? value) =>
    value?.clamp(0, maxAppLockBackgroundTimeoutMs) ?? defaultAppLockBackgroundTimeoutMs;

/// Android re-creates the Activity on a configuration change (rotation, theme, font scale). That is
/// not the user leaving the app, so it must not start the lock timer.
bool shouldRecordAppBackground({required bool isChangingConfigurations}) =>
    !isChangingConfigurations;

/// The editable state of the "lock after" setting, kept as a value type so the screen can preview a
/// change before committing it.
class AppLockTimeoutDraft {
  const AppLockTimeoutDraft({
    required this.timeoutMs,
    required this.customValue,
    required this.customUnit,
    required this.customSelected,
  });

  factory AppLockTimeoutDraft.fromTimeout(int timeoutMs) {
    final (value, unit) = _appLockCustomDurationParts(timeoutMs);
    return AppLockTimeoutDraft(
      timeoutMs: timeoutMs,
      customValue: value,
      customUnit: unit,
      customSelected: !_appLockTimeoutPresetValuesMs.contains(timeoutMs),
    );
  }

  final int timeoutMs;
  final String customValue;
  final String customUnit;
  final bool customSelected;

  int? get customTimeoutMs => parseAppLockCustomDuration(customValue, customUnit);

  bool get isValid => !customSelected || customTimeoutMs != null;

  AppLockTimeoutDraft copyWith({
    int? timeoutMs,
    String? customValue,
    String? customUnit,
    bool? customSelected,
  }) =>
      AppLockTimeoutDraft(
        timeoutMs: timeoutMs ?? this.timeoutMs,
        customValue: customValue ?? this.customValue,
        customUnit: customUnit ?? this.customUnit,
        customSelected: customSelected ?? this.customSelected,
      );

  AppLockTimeoutDraft selectPreset(int timeoutMs) =>
      copyWith(timeoutMs: timeoutMs, customSelected: false);

  /// Switching to custom seeds a sensible 10-minute value; re-selecting it is a no-op so the user's
  /// half-typed entry is not wiped.
  AppLockTimeoutDraft selectCustom() => customSelected
      ? this
      : copyWith(
          timeoutMs: 10 * 60 * 1000,
          customValue: '10',
          customUnit: 'Minutes',
          customSelected: true,
        );

  /// Digits only, capped at 5 characters. An unparseable entry leaves [timeoutMs] untouched rather
  /// than resetting it, so clearing the field mid-edit does not silently change the saved value.
  AppLockTimeoutDraft editCustomValue(String input) {
    final filtered =
        input.split('').where((c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39).join();
    final capped = filtered.length <= 5 ? filtered : filtered.substring(0, 5);
    return copyWith(
      customValue: capped,
      timeoutMs: parseAppLockCustomDuration(capped, customUnit) ?? timeoutMs,
    );
  }

  AppLockTimeoutDraft selectCustomUnit(String unit) => copyWith(
        customUnit: unit,
        timeoutMs: parseAppLockCustomDuration(customValue, unit) ?? timeoutMs,
      );

  @override
  bool operator ==(Object other) =>
      other is AppLockTimeoutDraft &&
      other.timeoutMs == timeoutMs &&
      other.customValue == customValue &&
      other.customUnit == customUnit &&
      other.customSelected == customSelected;

  @override
  int get hashCode => Object.hash(timeoutMs, customValue, customUnit, customSelected);
}

(String, String) _appLockCustomDurationParts(int timeoutMs) {
  if (timeoutMs > 0 && timeoutMs % 3600000 == 0) return ('${timeoutMs ~/ 3600000}', 'Hours');
  if (timeoutMs > 0 && timeoutMs % 60000 == 0) return ('${timeoutMs ~/ 60000}', 'Minutes');
  if (timeoutMs > 0) {
    final seconds = timeoutMs ~/ 1000;
    return ('${seconds < 1 ? 1 : seconds}', 'Seconds');
  }
  return ('10', 'Minutes');
}

int? parseAppLockCustomDuration(String value, String unit) {
  final amount = int.tryParse(value);
  if (amount == null || amount <= 0) return null;
  final multiplier = _appLockUnits[unit];
  if (multiplier == null) return null;
  final total = amount * multiplier;
  return (total >= 1 && total <= maxAppLockBackgroundTimeoutMs) ? total : null;
}

/// In-process foreground/background tracker for the app lock.
///
/// The timestamp is deliberately not persisted: process recreation is handled by the stricter
/// cold-start lock. Callers supply monotonic time so wall-clock changes cannot shorten or extend
/// the configured interval.
class AppLockTimeoutTracker {
  int? _backgroundedAtMs;

  void noteBackgrounded(int nowMs) {
    // Keep the earliest unmatched stop if the platform delivers duplicate lifecycle callbacks.
    _backgroundedAtMs ??= nowMs;
  }

  void clear() => _backgroundedAtMs = null;

  /// Consumes the pending background timestamp and reports whether the app must re-lock.
  ///
  /// Consuming unconditionally (even when locking is disabled) matches the Kotlin: a stale
  /// timestamp must never survive to trigger a lock on a later, unrelated resume.
  bool consumeShouldRelock({
    required int nowMs,
    required int timeoutMs,
    required bool lockEnabled,
    required bool hasPin,
  }) {
    final since = _backgroundedAtMs;
    if (since == null) return false;
    _backgroundedAtMs = null;
    // nowMs < since means the monotonic clock went backwards; treat it as no elapsed time rather
    // than as an enormous one.
    if (!lockEnabled || !hasPin || nowMs < since) return false;
    return nowMs - since >= normalizeAppLockBackgroundTimeout(timeoutMs);
  }
}
