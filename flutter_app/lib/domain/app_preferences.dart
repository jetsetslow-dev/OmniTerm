/// The user-facing preferences, as a typed value rather than a bag of strings.
///
/// Every field maps to one row in `app_settings`, under the key the Android app already uses — so an
/// upgraded install keeps its choices instead of silently reverting to defaults. That is data
/// compatibility, like §7.10 and the backup envelope, not historical residue (§16.4).
///
/// The clamping matters more than it looks. These values feed timers, buffers and retention
/// windows; a telemetry interval of zero busy-loops the radio, and a scrollback of two million lines
/// exhausts memory on a phone. Rather than trusting the stored text, every read is bounded.
library;

import 'app_lock_timeout_policy.dart';
import 'measurement_units.dart';

export 'measurement_units.dart' show MeasurementSystem;

/// The terminal colour schemes offered, keyed exactly as the Kotlin app persists them.
///
/// Labels are presentation only. Persisting labels here previously made every upgraded Kotlin
/// value fail validation and silently reset the terminal to a Flutter-only default.
const terminalThemes = <String, String>{
  'system': 'App theme',
  'omni_dark': 'Omni Dark',
  'solarized_dark': 'Solarized',
  'matrix': 'Matrix',
  'light': 'Light',
};

/// Bounds for a preference, with the default used when a stored value is missing or unusable.
///
/// Public so the editor can label a field with its own limits rather than repeating the numbers,
/// which is how a UI and its validation drift apart.
class PreferenceRange {
  const PreferenceRange(this.min, this.max, this.fallback);

  final int min;
  final int max;
  final int fallback;

  int clamp(int? value) => value == null ? fallback : value.clamp(min, max);

  int parse(String? text) => clamp(int.tryParse(text?.trim() ?? ''));
}

/// The preference bounds, named so the UI can describe them without duplicating the numbers.
class PreferenceLimits {
  const PreferenceLimits._();

  /// Seconds between telemetry polls. The floor stops a poll storm that would flatten a battery and
  /// hammer every host; the ceiling keeps "live" meaning something.
  static const telemetryInterval = PreferenceRange(5, 300, 15);

  /// Days of metric history kept. Zero would discard the charts entirely.
  static const metricsRetention = PreferenceRange(1, 365, 7);

  /// Resolved alerts kept per host.
  static const alertHistoryLimit = PreferenceRange(10, 1000, 100);

  static const terminalFontSize = PreferenceRange(8, 32, 13);

  /// Terminal scrollback lines. The ceiling is a memory bound, not a preference.
  static const terminalScrollback = PreferenceRange(500, 100000, 5000);

  /// Largest file the editor will syntax-highlight, in kilobytes. Highlighting a huge file blocks
  /// the frame long enough to look like a hang.
  static const editorHighlightLimit = PreferenceRange(16, 4096, 256);

  /// Battery percentage below which polling backs off.
  static const batterySaverThreshold = PreferenceRange(5, 95, 20);

  /// How many files in one SFTP transfer before the app warns.
  static const sftpWarnFileCount = PreferenceRange(1, 10000, 50);

  /// How many gigabytes in one SFTP transfer before the app warns.
  static const sftpWarnGigabytes = PreferenceRange(1, 1000, 2);

  /// Text scale, as a percentage of the system size.
  static const textScalePercent = PreferenceRange(80, 200, 100);
}

/// A snapshot of every preference.
class AppPreferences {
  const AppPreferences({
    this.darkMode,
    this.amoled = false,
    this.textScalePercent = 100,
    this.accessibility = false,
    this.measurementSystem = MeasurementSystem.metric,
    this.telemetryIntervalSeconds = 15,
    this.metricsRetentionDays = 7,
    this.alertHistoryLimit = 100,
    this.keepScreenOn = false,
    this.backgroundKeepAlive = false,
    this.batterySaverEnabled = true,
    this.batterySaverThresholdPercent = 20,
    this.terminalFontSize = 13,
    this.terminalTheme = 'system',
    this.terminalScrollbackLimit = 5000,
    this.smartSwipeInput = false,
    this.terminalLinkDetection = true,
    this.linkOpenInApp = true,
    this.tmuxControlMode = false,
    this.editorHighlightLimitKb = 256,
    this.appLockEnabled = false,
    this.appLockTimeoutMs = defaultAppLockBackgroundTimeoutMs,
    this.useBiometrics = false,
    this.blockScreenshots = false,
    this.hideSensitiveInfo = false,
    this.sftpWarnFileCount = 50,
    this.sftpWarnGigabytes = 2,
  });

  final bool? darkMode;
  final bool amoled;
  final int textScalePercent;
  final bool accessibility;
  final MeasurementSystem measurementSystem;

  final int telemetryIntervalSeconds;
  final int metricsRetentionDays;
  final int alertHistoryLimit;
  final bool keepScreenOn;
  final bool backgroundKeepAlive;
  final bool batterySaverEnabled;
  final int batterySaverThresholdPercent;

  final int terminalFontSize;
  final String terminalTheme;
  final int terminalScrollbackLimit;
  final bool smartSwipeInput;
  final bool terminalLinkDetection;
  final bool linkOpenInApp;
  final bool tmuxControlMode;
  final int editorHighlightLimitKb;

  final bool appLockEnabled;

  /// How long OmniTerm may be off screen before it locks again.
  ///
  /// Stored under the Android app's own `app_lock_grace_ms` key so a device upgrading from the
  /// Kotlin build keeps the interval it was configured with, rather than silently reverting to the
  /// 30-second default.
  final int appLockTimeoutMs;
  final bool useBiometrics;
  final bool blockScreenshots;
  final bool hideSensitiveInfo;

  final int sftpWarnFileCount;
  final int sftpWarnGigabytes;

  static const defaults = AppPreferences();

  /// The `app_settings` keys, in the Android app's spelling.
  static const keys = {
    'darkMode': 'dark_mode',
    'amoled': 'amoled',
    'textScale': 'text_scale',
    'accessibility': 'accessibility',
    'measurementSystem': 'measurement_system',
    'telemetryInterval': 'telemetry_interval',
    'metricsRetention': 'metrics_retention',
    'alertHistoryLimit': 'alert_history_limit',
    'keepScreenOn': 'keep_screen_on',
    'backgroundKeepAlive': 'background_keep_alive',
    'batterySaverEnabled': 'battery_saver_enabled',
    'batterySaverThreshold': 'battery_saver_threshold',
    'terminalFontSize': 'terminal_font_size',
    'terminalTheme': 'terminal_theme',
    'terminalScrollbackLimit': 'terminal_scrollback_limit',
    'smartSwipe': 'terminal_smart_swipe',
    'linkDetection': 'terminal_link_detection',
    'linkOpenInApp': 'link_open_in_app',
    'tmuxControlMode': 'tmux_control_mode',
    'editorHighlightLimit': 'editor_highlight_limit',
    'appLockEnabled': 'app_lock_enabled',
    'appLockTimeout': 'app_lock_grace_ms',
    'biometrics': 'biometrics_enabled',
    'blockScreenshots': 'flag_secure',
    'hideSensitiveInfo': 'hide_sensitive_info',
    'sftpWarnFileCount': 'sftp_large_batch_file_threshold',
    'sftpWarnBytes': 'sftp_large_batch_bytes_threshold',
  };

  /// Reads preferences from raw settings rows, bounding every numeric value.
  ///
  /// A missing or unparseable row falls back to the default rather than failing: one corrupt
  /// settings row must never stop the app starting.
  static AppPreferences decode(Map<String, String> settings) {
    bool flag(String key, {required bool fallback}) {
      final value = settings[keys[key]]?.trim().toLowerCase();
      if (value == 'true') return true;
      if (value == 'false') return false;
      return fallback;
    }

    bool? nullableFlag(String key) {
      final value = settings[keys[key]]?.trim().toLowerCase();
      if (value == 'true') return true;
      if (value == 'false') return false;
      return null;
    }

    // Stored in bytes; shown in gigabytes, because nobody reasons about a transfer warning in bytes.
    final warnBytes = int.tryParse(settings[keys['sftpWarnBytes']] ?? '');
    final warnGigabytes = warnBytes == null
        ? PreferenceLimits.sftpWarnGigabytes.fallback
        : PreferenceLimits.sftpWarnGigabytes.clamp(warnBytes ~/ 1000000000);

    return AppPreferences(
      darkMode: nullableFlag('darkMode'),
      amoled: flag('amoled', fallback: defaults.amoled),
      textScalePercent: PreferenceLimits.textScalePercent.parse(settings[keys['textScale']]),
      accessibility: flag('accessibility', fallback: defaults.accessibility),
      measurementSystem: MeasurementSystem.fromSetting(settings[keys['measurementSystem']]),
      telemetryIntervalSeconds: PreferenceLimits.telemetryInterval.parse(
        settings[keys['telemetryInterval']],
      ),
      metricsRetentionDays: PreferenceLimits.metricsRetention.parse(
        settings[keys['metricsRetention']],
      ),
      alertHistoryLimit: PreferenceLimits.alertHistoryLimit.parse(
        settings[keys['alertHistoryLimit']],
      ),
      keepScreenOn: flag('keepScreenOn', fallback: defaults.keepScreenOn),
      backgroundKeepAlive: flag('backgroundKeepAlive', fallback: defaults.backgroundKeepAlive),
      batterySaverEnabled: flag('batterySaverEnabled', fallback: defaults.batterySaverEnabled),
      batterySaverThresholdPercent: PreferenceLimits.batterySaverThreshold.parse(
        settings[keys['batterySaverThreshold']],
      ),
      terminalFontSize: PreferenceLimits.terminalFontSize.parse(settings[keys['terminalFontSize']]),
      terminalTheme: terminalThemes.containsKey(settings[keys['terminalTheme']])
          ? settings[keys['terminalTheme']]!
          : defaults.terminalTheme,
      terminalScrollbackLimit: PreferenceLimits.terminalScrollback.parse(
        settings[keys['terminalScrollbackLimit']],
      ),
      smartSwipeInput: flag('smartSwipe', fallback: defaults.smartSwipeInput),
      terminalLinkDetection: flag('linkDetection', fallback: defaults.terminalLinkDetection),
      linkOpenInApp: flag('linkOpenInApp', fallback: defaults.linkOpenInApp),
      tmuxControlMode: flag('tmuxControlMode', fallback: defaults.tmuxControlMode),
      editorHighlightLimitKb: PreferenceLimits.editorHighlightLimit.parse(
        settings[keys['editorHighlightLimit']],
      ),
      appLockEnabled: flag('appLockEnabled', fallback: defaults.appLockEnabled),
      appLockTimeoutMs: normalizeAppLockBackgroundTimeout(
        int.tryParse(settings[keys['appLockTimeout']] ?? ''),
      ),
      useBiometrics: flag('biometrics', fallback: defaults.useBiometrics),
      blockScreenshots: flag('blockScreenshots', fallback: defaults.blockScreenshots),
      hideSensitiveInfo: flag('hideSensitiveInfo', fallback: defaults.hideSensitiveInfo),
      sftpWarnFileCount: PreferenceLimits.sftpWarnFileCount.parse(
        settings[keys['sftpWarnFileCount']],
      ),
      sftpWarnGigabytes: warnGigabytes,
    );
  }

  /// The rows to write. Only what this screen owns — nothing else in `app_settings` is touched.
  Map<String, String> encode() => {
    if (darkMode != null) keys['darkMode']!: '$darkMode',
    keys['amoled']!: '$amoled',
    keys['textScale']!: '$textScalePercent',
    keys['accessibility']!: '$accessibility',
    keys['measurementSystem']!: measurementSystem.settingValue,
    keys['telemetryInterval']!: '$telemetryIntervalSeconds',
    keys['metricsRetention']!: '$metricsRetentionDays',
    keys['alertHistoryLimit']!: '$alertHistoryLimit',
    keys['keepScreenOn']!: '$keepScreenOn',
    keys['backgroundKeepAlive']!: '$backgroundKeepAlive',
    keys['batterySaverEnabled']!: '$batterySaverEnabled',
    keys['batterySaverThreshold']!: '$batterySaverThresholdPercent',
    keys['terminalFontSize']!: '$terminalFontSize',
    keys['terminalTheme']!: terminalTheme,
    keys['terminalScrollbackLimit']!: '$terminalScrollbackLimit',
    keys['smartSwipe']!: '$smartSwipeInput',
    keys['linkDetection']!: '$terminalLinkDetection',
    keys['linkOpenInApp']!: '$linkOpenInApp',
    keys['tmuxControlMode']!: '$tmuxControlMode',
    keys['editorHighlightLimit']!: '$editorHighlightLimitKb',
    keys['appLockEnabled']!: '$appLockEnabled',
    keys['appLockTimeout']!: '$appLockTimeoutMs',
    keys['biometrics']!: '$useBiometrics',
    keys['blockScreenshots']!: '$blockScreenshots',
    keys['hideSensitiveInfo']!: '$hideSensitiveInfo',
    keys['sftpWarnFileCount']!: '$sftpWarnFileCount',
    keys['sftpWarnBytes']!: '${sftpWarnGigabytes * 1000000000}',
  };

  AppPreferences copyWith({
    bool? darkMode,
    bool clearDarkMode = false,
    bool? amoled,
    int? textScalePercent,
    bool? accessibility,
    MeasurementSystem? measurementSystem,
    int? telemetryIntervalSeconds,
    int? metricsRetentionDays,
    int? alertHistoryLimit,
    bool? keepScreenOn,
    bool? backgroundKeepAlive,
    bool? batterySaverEnabled,
    int? batterySaverThresholdPercent,
    int? terminalFontSize,
    String? terminalTheme,
    int? terminalScrollbackLimit,
    bool? smartSwipeInput,
    bool? terminalLinkDetection,
    bool? linkOpenInApp,
    bool? tmuxControlMode,
    int? editorHighlightLimitKb,
    bool? appLockEnabled,
    int? appLockTimeoutMs,
    bool? useBiometrics,
    bool? blockScreenshots,
    bool? hideSensitiveInfo,
    int? sftpWarnFileCount,
    int? sftpWarnGigabytes,
  }) => AppPreferences(
    darkMode: clearDarkMode ? null : (darkMode ?? this.darkMode),
    amoled: amoled ?? this.amoled,
    textScalePercent: textScalePercent ?? this.textScalePercent,
    accessibility: accessibility ?? this.accessibility,
    measurementSystem: measurementSystem ?? this.measurementSystem,
    telemetryIntervalSeconds: telemetryIntervalSeconds ?? this.telemetryIntervalSeconds,
    metricsRetentionDays: metricsRetentionDays ?? this.metricsRetentionDays,
    alertHistoryLimit: alertHistoryLimit ?? this.alertHistoryLimit,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    backgroundKeepAlive: backgroundKeepAlive ?? this.backgroundKeepAlive,
    batterySaverEnabled: batterySaverEnabled ?? this.batterySaverEnabled,
    batterySaverThresholdPercent: batterySaverThresholdPercent ?? this.batterySaverThresholdPercent,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    terminalTheme: terminalTheme ?? this.terminalTheme,
    terminalScrollbackLimit: terminalScrollbackLimit ?? this.terminalScrollbackLimit,
    smartSwipeInput: smartSwipeInput ?? this.smartSwipeInput,
    terminalLinkDetection: terminalLinkDetection ?? this.terminalLinkDetection,
    linkOpenInApp: linkOpenInApp ?? this.linkOpenInApp,
    tmuxControlMode: tmuxControlMode ?? this.tmuxControlMode,
    editorHighlightLimitKb: editorHighlightLimitKb ?? this.editorHighlightLimitKb,
    appLockEnabled: appLockEnabled ?? this.appLockEnabled,
    appLockTimeoutMs: appLockTimeoutMs ?? this.appLockTimeoutMs,
    useBiometrics: useBiometrics ?? this.useBiometrics,
    blockScreenshots: blockScreenshots ?? this.blockScreenshots,
    hideSensitiveInfo: hideSensitiveInfo ?? this.hideSensitiveInfo,
    sftpWarnFileCount: sftpWarnFileCount ?? this.sftpWarnFileCount,
    sftpWarnGigabytes: sftpWarnGigabytes ?? this.sftpWarnGigabytes,
  );

  /// Rules that are not per-field bounds but relationships between fields.
  ///
  /// Returned as a warning rather than a block: each describes a combination that is legal but
  /// probably not what was meant, and refusing it outright would be the app overruling the user.
  List<String> get warnings => [
    if (!appLockEnabled && useBiometrics)
      'Biometric unlock does nothing while the app lock is off.',
    if (batterySaverEnabled && batterySaverThresholdPercent >= 90)
      'Battery saver at $batterySaverThresholdPercent% will be active almost all the time.',
    if (telemetryIntervalSeconds <= 10)
      'Polling every $telemetryIntervalSeconds seconds is hard on battery and on the hosts.',
    if (backgroundKeepAlive && batterySaverEnabled)
      'Battery saver pauses background polling, so keep-alive will stop below the threshold.',
  ];

  @override
  bool operator ==(Object other) => other is AppPreferences && _mapEquals(other.encode(), encode());

  @override
  int get hashCode => Object.hashAll(encode().entries.map((e) => '${e.key}=${e.value}'));

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
