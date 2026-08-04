import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';

import 'support/fake_secure_storage.dart';

/// These values feed timers, buffers and retention windows. A telemetry interval of zero busy-loops
/// the radio and a scrollback of two million lines exhausts memory, so nothing stored is trusted
/// unbounded.
void main() {
  group('decode', () {
    test('an empty store yields the defaults', () {
      expect(AppPreferences.decode(const {}), AppPreferences.defaults);
    });

    test('reads the keys the Android app already writes', () {
      // An upgraded install must keep its choices rather than silently reverting.
      final prefs = AppPreferences.decode({
        'dark_mode': 'false',
        'amoled': 'true',
        'telemetry_interval': '30',
        'terminal_theme': 'Dracula',
        'measurement_system': 'imperial',
        'hide_sensitive_info': 'true',
      });

      expect(prefs.darkMode, isFalse);
      expect(prefs.amoled, isTrue);
      expect(prefs.telemetryIntervalSeconds, 30);
      expect(prefs.terminalTheme, 'Dracula');
      expect(prefs.measurementSystem, MeasurementSystem.imperial);
      expect(prefs.hideSensitiveInfo, isTrue);
    });

    test('an unparseable number falls back rather than failing the whole load', () {
      // One corrupt row must never stop the app starting.
      final prefs = AppPreferences.decode({'telemetry_interval': 'soon'});
      expect(prefs.telemetryIntervalSeconds, AppPreferences.defaults.telemetryIntervalSeconds);
    });

    test('an unparseable flag falls back too', () {
      expect(AppPreferences.decode({'amoled': 'yes'}).amoled, AppPreferences.defaults.amoled);
    });

    test('an unknown terminal theme falls back to a real one', () {
      // Otherwise the terminal would try to render with a scheme that does not exist.
      expect(
        AppPreferences.decode({'terminal_theme': 'Neon Dreams'}).terminalTheme,
        AppPreferences.defaults.terminalTheme,
      );
      expect(terminalThemes, contains(AppPreferences.defaults.terminalTheme));
    });
  });

  group('bounds', () {
    test('a zero poll interval is raised to the floor', () {
      // Zero would busy-loop the radio and hammer every host.
      expect(AppPreferences.decode({'telemetry_interval': '0'}).telemetryIntervalSeconds,
          PreferenceLimits.telemetryInterval.min);
    });

    test('an absurd poll interval is capped, so "live" still means something', () {
      expect(AppPreferences.decode({'telemetry_interval': '99999'}).telemetryIntervalSeconds,
          PreferenceLimits.telemetryInterval.max);
    });

    test('a huge scrollback is capped — it is a memory bound, not a preference', () {
      expect(
        AppPreferences.decode({'terminal_scrollback_limit': '2000000'}).terminalScrollbackLimit,
        PreferenceLimits.terminalScrollback.max,
      );
    });

    test('a negative value is raised to the floor', () {
      final prefs = AppPreferences.decode({
        'metrics_retention': '-5',
        'terminal_font_size': '-1',
        'alert_history_limit': '0',
      });
      expect(prefs.metricsRetentionDays, PreferenceLimits.metricsRetention.min);
      expect(prefs.terminalFontSize, PreferenceLimits.terminalFontSize.min);
      expect(prefs.alertHistoryLimit, PreferenceLimits.alertHistoryLimit.min);
    });

    test('every limit has a default inside its own range', () {
      // A default outside its bounds would be silently rewritten on the first read.
      for (final (limit, value) in [
        (PreferenceLimits.telemetryInterval, AppPreferences.defaults.telemetryIntervalSeconds),
        (PreferenceLimits.metricsRetention, AppPreferences.defaults.metricsRetentionDays),
        (PreferenceLimits.alertHistoryLimit, AppPreferences.defaults.alertHistoryLimit),
        (PreferenceLimits.terminalFontSize, AppPreferences.defaults.terminalFontSize),
        (PreferenceLimits.terminalScrollback, AppPreferences.defaults.terminalScrollbackLimit),
        (PreferenceLimits.editorHighlightLimit, AppPreferences.defaults.editorHighlightLimitKb),
        (
          PreferenceLimits.batterySaverThreshold,
          AppPreferences.defaults.batterySaverThresholdPercent
        ),
        (PreferenceLimits.sftpWarnFileCount, AppPreferences.defaults.sftpWarnFileCount),
        (PreferenceLimits.sftpWarnGigabytes, AppPreferences.defaults.sftpWarnGigabytes),
        (PreferenceLimits.textScalePercent, AppPreferences.defaults.textScalePercent),
      ]) {
        expect(value, inInclusiveRange(limit.min, limit.max));
      }
    });
  });

  group('round trip', () {
    test('encode then decode preserves every field', () {
      const prefs = AppPreferences(
        darkMode: false,
        amoled: true,
        textScalePercent: 130,
        accessibility: true,
        measurementSystem: MeasurementSystem.imperial,
        telemetryIntervalSeconds: 45,
        metricsRetentionDays: 30,
        alertHistoryLimit: 250,
        keepScreenOn: true,
        backgroundKeepAlive: true,
        batterySaverEnabled: false,
        batterySaverThresholdPercent: 35,
        terminalFontSize: 16,
        terminalTheme: 'Nord',
        terminalScrollbackLimit: 20000,
        smartSwipeInput: false,
        terminalLinkDetection: false,
        linkOpenInApp: false,
        tmuxControlMode: true,
        editorHighlightLimitKb: 1024,
        appLockEnabled: true,
        useBiometrics: true,
        blockScreenshots: true,
        hideSensitiveInfo: true,
        sftpWarnFileCount: 200,
        sftpWarnGigabytes: 5,
      );

      expect(AppPreferences.decode(prefs.encode()), prefs);
    });

    test('the SFTP size warning is stored in bytes but edited in gigabytes', () {
      // Nobody reasons about a transfer warning in bytes.
      const prefs = AppPreferences(sftpWarnGigabytes: 3);
      expect(prefs.encode()['sftp_large_batch_bytes_threshold'], '3000000000');
      expect(AppPreferences.decode(prefs.encode()).sftpWarnGigabytes, 3);
    });

    test('a sub-gigabyte stored value is raised to the floor rather than becoming zero', () {
      expect(
        AppPreferences.decode({'sftp_large_batch_bytes_threshold': '500'}).sftpWarnGigabytes,
        PreferenceLimits.sftpWarnGigabytes.min,
      );
    });

    test('encode writes only the keys this screen owns', () {
      // Saving preferences must not clobber a bookmark list or a preset toggle.
      final written = AppPreferences.defaults.encode().keys.toSet();
      for (final foreign in [
        'sftp_bookmarks_1',
        'health_scoring',
        'fleet_presets',
        'alert_presets',
        'app_pin',
        'first_run_complete',
      ]) {
        expect(written, isNot(contains(foreign)), reason: foreign);
      }
    });

    test('the app PIN is never among them', () {
      expect(AppPreferences.defaults.encode().containsKey('app_pin'), isFalse);
    });
  });

  group('warnings', () {
    test('biometrics without the app lock is flagged', () {
      // It silently does nothing, which is worse than being refused.
      const prefs = AppPreferences(appLockEnabled: false, useBiometrics: true);
      expect(prefs.warnings, contains(contains('does nothing while the app lock is off')));
    });

    test('an always-on battery saver is flagged', () {
      const prefs = AppPreferences(batterySaverEnabled: true, batterySaverThresholdPercent: 95);
      expect(prefs.warnings, contains(contains('almost all the time')));
    });

    test('a very fast poll is flagged', () {
      const prefs = AppPreferences(telemetryIntervalSeconds: 5);
      expect(prefs.warnings, contains(contains('hard on battery')));
    });

    test('keep-alive with battery saver is flagged, because they conflict', () {
      const prefs = AppPreferences(backgroundKeepAlive: true, batterySaverEnabled: true);
      expect(prefs.warnings, contains(contains('keep-alive will stop')));
    });

    test('warnings do not block — they are advice, not a veto', () {
      // Refusing a legal combination outright would be the app overruling the user.
      const prefs = AppPreferences(appLockEnabled: false, useBiometrics: true);
      expect(AppPreferences.decode(prefs.encode()), prefs);
    });

    test('a sensible configuration warns about nothing', () {
      expect(AppPreferences.defaults.warnings, isEmpty);
    });
  });

  group('the editor', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
      HostDisplay.instance.hideSensitiveInfo = false;
    });

    tearDown(() async {
      app.dispose();
      await db.close();
    });

    Future<SettingsViewModel> boot() async {
      await app.start();
      final vm = SettingsViewModel(app);
      await vm.start();
      return vm;
    }

    test('loads what is stored', () async {
      await repo.insertSetting('telemetry_interval', '60');
      final vm = await boot();
      expect(vm.saved.telemetryIntervalSeconds, 60);
      expect(vm.isDirty, isFalse);
      vm.dispose();
    });

    test('editing does not touch the database until saved', () async {
      // Applying per keystroke would restart the telemetry poller on the way from "1" to "15".
      final vm = await boot();
      vm.update((p) => p.copyWith(telemetryIntervalSeconds: 60));

      expect(vm.isDirty, isTrue);
      expect(vm.saved.telemetryIntervalSeconds, 15);
      expect(await repo.getSetting('telemetry_interval'), isNull);
      vm.dispose();
    });

    test('saving persists and clears the dirty state', () async {
      final vm = await boot();
      vm.update((p) => p.copyWith(terminalTheme: 'Nord', terminalFontSize: 18));
      await vm.save();

      expect(vm.isDirty, isFalse);
      expect(await repo.getSetting('terminal_theme'), 'Nord');
      expect(await repo.getSetting('terminal_font_size'), '18');
      vm.dispose();
    });

    test('saving leaves unrelated settings alone', () async {
      await repo.insertSetting('sftp_bookmarks_1', '/srv|||/etc');
      await repo.insertSetting('fleet_presets', 'true');
      final vm = await boot();

      vm.update((p) => p.copyWith(darkMode: false));
      await vm.save();

      expect(await repo.getSetting('sftp_bookmarks_1'), '/srv|||/etc');
      expect(await repo.getSetting('fleet_presets'), 'true');
      vm.dispose();
    });

    test('reverting throws the draft away', () async {
      final vm = await boot();
      vm.update((p) => p.copyWith(amoled: true));
      expect(vm.isDirty, isTrue);

      vm.revert();
      expect(vm.isDirty, isFalse);
      expect(vm.draft.amoled, AppPreferences.defaults.amoled);
      vm.dispose();
    });

    test('resetting restores and persists the defaults', () async {
      await repo.insertSetting('telemetry_interval', '120');
      final vm = await boot();
      expect(vm.saved.telemetryIntervalSeconds, 120);

      await vm.resetToDefaults();

      expect(vm.saved, AppPreferences.defaults);
      expect(await repo.getSetting('telemetry_interval'), '15');
      vm.dispose();
    });

    test('hide-sensitive-info reaches the live singleton on load and on save', () async {
      // Every screen that renders an address observes HostDisplay directly, so it has to be told
      // rather than waiting to be read again.
      await repo.insertSetting('hide_sensitive_info', 'true');
      final vm = await boot();
      expect(HostDisplay.instance.hideSensitiveInfo, isTrue);

      vm.update((p) => p.copyWith(hideSensitiveInfo: false));
      await vm.save();
      expect(HostDisplay.instance.hideSensitiveInfo, isFalse);
      vm.dispose();
    });

    test('warnings follow the draft, not the saved values', () async {
      final vm = await boot();
      expect(vm.warnings, isEmpty);

      vm.update((p) => p.copyWith(useBiometrics: true));
      expect(vm.warnings, isNotEmpty, reason: 'the app lock is still off');
      vm.dispose();
    });
  });
}
