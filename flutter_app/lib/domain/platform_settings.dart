/// Settings that cannot work on every platform the app runs on.
///
/// The Kotlin app is Android-only, so there is no parity reference here — this exists because a
/// toggle that persists, looks live and does nothing is the same defect as the read-only key bar
/// (47) and the inert high-contrast theme (44). A user who turns on "keep polling in the background"
/// on an iPhone has been told something untrue about their own device.
///
/// Stated rather than hidden. A setting that silently vanishes on one platform reads as the app
/// having forgotten it, and it is still carried in backups taken on the other.
library;

/// Why a setting is unavailable, or null when it works here.
String? settingUnavailableReason(String settingKey, {required bool isIOS}) {
  if (!isIOS) return null;
  return switch (settingKey) {
    // No foreground service equivalent. `SessionService` documents the same thing on the platform
    // side: iOS genuinely does not allow it, rather than the app not having got to it.
    'backgroundKeepAlive' =>
      'iOS stops background work when you leave the app, so this has no effect here.',
    // `FLAG_SECURE` has no iOS counterpart — there is no API to block a screenshot, which
    // `ScreenSecurityBridge.swift` says in as many words rather than pretending otherwise.
    'blockScreenshots' => 'iOS provides no way to block screenshots, so this has no effect here.',
    _ => null,
  };
}

/// Whether the setting does anything on this platform.
bool settingAvailable(String settingKey, {required bool isIOS}) =>
    settingUnavailableReason(settingKey, isIOS: isIOS) == null;
