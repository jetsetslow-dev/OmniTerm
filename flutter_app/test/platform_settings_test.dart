import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/platform_settings.dart';

/// Settings the running platform cannot honour.
///
/// No Kotlin counterpart — that app is Android-only. This exists because a toggle that persists,
/// looks live and does nothing is the same defect as the read-only key bar (38) and the inert
/// high-contrast theme (44): the app telling the user something untrue about their own device.
void main() {
  group('on Android everything is available', () {
    test('the two platform-bound settings work', () {
      expect(settingAvailable('backgroundKeepAlive', isIOS: false), isTrue);
      expect(settingAvailable('blockScreenshots', isIOS: false), isTrue);
      expect(settingUnavailableReason('backgroundKeepAlive', isIOS: false), isNull);
    });
  });

  group('on iOS', () {
    test('background polling is unavailable and says why', () {
      expect(settingAvailable('backgroundKeepAlive', isIOS: true), isFalse);
      expect(
        settingUnavailableReason('backgroundKeepAlive', isIOS: true),
        contains('background work'),
      );
    });

    test('screenshot blocking is unavailable and says why', () {
      // `ScreenSecurityBridge.swift` says the same on the platform side rather than pretending
      // there is an API for it.
      expect(settingAvailable('blockScreenshots', isIOS: true), isFalse);
      expect(
        settingUnavailableReason('blockScreenshots', isIOS: true),
        contains('no way to block screenshots'),
      );
    });

    test('every other setting is untouched', () {
      // The rule must name specific keys, not disable settings it has no opinion about.
      for (final key in const [
        'darkMode',
        'biometrics',
        'appLockEnabled',
        'hideSensitiveInfo',
        'terminalTheme',
        'batterySaverEnabled',
      ]) {
        expect(settingAvailable(key, isIOS: true), isTrue, reason: key);
      }
    });

    test('an unknown key is available rather than silently disabled', () {
      // A new setting must not be dead on iOS because nobody added it here.
      expect(settingAvailable('somethingAddedLater', isIOS: true), isTrue);
    });
  });
}
