import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/alert_breach_tracker.dart';
import 'package:omniterm/domain/file_edit.dart';
import 'package:omniterm/domain/app_lock_timeout_policy.dart';
import 'package:omniterm/domain/input_validation.dart';
import 'package:omniterm/domain/measurement_units.dart';
import 'package:omniterm/domain/operation_generation.dart';
import 'package:omniterm/domain/script_filters.dart';
import 'package:omniterm/domain/terminal_key_encoder.dart';

/// Ported from AlertBreachTrackerTest, AppLockTimeoutPolicyTest, InputValidationTest,
/// MeasurementUnitsTest and OperationGenerationTest, reusing their fixtures and expectations.
void main() {
  group('AlertBreachTracker', () {
    const key = (1, 4);
    const window = 5 * 60000; // 5m rule
    const gap = 90000; // stale-gap threshold
    const poll = 15000; // sample cadence

    bool sample(AlertBreachTracker t, BreachKey k, bool over, int now) =>
        t.onSample(k, over: over, now: now, windowMs: window, staleGapMs: gap);

    test('a sustained breach fires after the window', () {
      final t = AlertBreachTracker();
      var now = 0;
      var fired = false;
      // 21 samples * 15s = 5m elapsed at the last one.
      for (var i = 0; i < 21; i++) {
        fired = sample(t, key, true, now);
        now += poll;
      }
      expect(fired, isTrue);
    });

    test('a breach shorter than the window does not fire', () {
      final t = AlertBreachTracker();
      var now = 0;
      for (var i = 0; i < 10; i++) {
        expect(sample(t, key, true, now), isFalse);
        now += poll;
      }
    });

    test('a single jitter dip does not reset the window', () {
      final t = AlertBreachTracker();
      var now = 0;
      for (var i = 0; i < 10; i++) {
        sample(t, key, true, now);
        now += poll;
      }
      sample(t, key, false, now);
      now += poll;

      // Continue the breach: the window must still be anchored at t=0.
      var fired = false;
      while (now <= window) {
        fired = sample(t, key, true, now);
        now += poll;
      }
      expect(fired, isTrue, reason: 'a dip must not restart the sustained-breach window');
    });

    test('two consecutive clean samples reset the window', () {
      final t = AlertBreachTracker();
      var now = 0;
      for (var i = 0; i < 30; i++) {
        sample(t, key, true, now);
        now += poll;
      }
      for (var i = 0; i < 2; i++) {
        sample(t, key, false, now);
        now += poll;
      }
      expect(t.clearedFor(key), isTrue);
      // A fresh breach starts a fresh window: no instant fire.
      expect(sample(t, key, true, now), isFalse);
    });

    test('a sampling gap restarts the window instead of instantly firing', () {
      final t = AlertBreachTracker();
      var now = 0;
      for (var i = 0; i < 4; i++) {
        sample(t, key, true, now);
        now += poll;
      }
      // App paused / host unreachable for 20 minutes; still over threshold on resume.
      now += 20 * 60000;
      expect(
        sample(t, key, true, now),
        isFalse,
        reason: 'unobserved time must not count toward the breach window',
      );

      // But a fresh sustained window after the gap does fire.
      var fired = false;
      final restart = now;
      while (now - restart <= window) {
        fired = sample(t, key, true, now);
        now += poll;
      }
      expect(fired, isTrue);
    });

    test('an incident resolves only after hysteresis', () {
      final t = AlertBreachTracker();
      var now = 0;
      for (var i = 0; i < 30; i++) {
        sample(t, key, true, now);
        now += poll;
      }
      sample(t, key, false, now);
      now += poll;
      expect(t.clearedFor(key), isFalse, reason: 'one clean sample must not resolve the incident');
      sample(t, key, false, now);
      expect(t.clearedFor(key), isTrue);
    });

    test('a never-breached key reports cleared', () {
      // An incident restored from a previous app run has no in-memory state; the first clean sample
      // may resolve it immediately.
      expect(AlertBreachTracker().clearedFor(key), isTrue);
    });

    test('forget drops state', () {
      final t = AlertBreachTracker();
      sample(t, key, true, 0);
      t.forget(key);
      expect(t.clearedFor(key), isTrue);
      expect(sample(t, key, true, window + 1), isFalse);
    });

    test('editing a rule drops unfired windows for every host', () {
      final t = AlertBreachTracker();
      const otherHost = (1, 99);
      sample(t, key, true, 0);
      sample(t, otherHost, true, 0);

      t.forgetRule(1);

      expect(t.clearedFor(key), isTrue);
      expect(t.clearedFor(otherHost), isTrue);
      expect(sample(t, key, true, window + 1), isFalse);
    });

    test('rules are tracked independently per host', () {
      final t = AlertBreachTracker();
      const hostA = (1, 4);
      const hostB = (1, 5);
      var now = 0;
      for (var i = 0; i < 21; i++) {
        sample(t, hostA, true, now);
        now += poll;
      }
      // hostB only just started breaching, so it must not inherit hostA's elapsed window.
      expect(sample(t, hostB, true, now), isFalse);
    });
  });

  group('OperationGeneration', () {
    test('a newer request invalidates an older completion for the same key', () {
      final generations = OperationGeneration<int>();
      final first = generations.begin([7])[7]!;
      final second = generations.begin([7])[7]!;

      expect(generations.isCurrent(7, first), isFalse);
      expect(generations.isCurrent(7, second), isTrue);
    });

    test('independent keys do not invalidate each other', () {
      final generations = OperationGeneration<int>();
      final first = generations.begin([7, 9]);
      generations.begin([7]);

      expect(generations.isCurrent(7, first[7]!), isFalse);
      expect(generations.isCurrent(9, first[9]!), isTrue);
    });

    test('a forgotten key cannot publish an in-flight completion', () {
      final generations = OperationGeneration<int>();
      final generation = generations.begin([7])[7]!;
      generations.forget([7]);

      expect(generations.isCurrent(7, generation), isFalse);
    });

    test('a stale generation cannot run publication', () {
      final generations = OperationGeneration<int>();
      final stale = generations.begin([7])[7]!;
      generations.begin([7]);
      var published = false;

      final accepted = generations.publishIfCurrent(7, stale, () => published = true);

      expect(accepted, isFalse);
      expect(published, isFalse);
    });

    test('the current generation does publish', () {
      final generations = OperationGeneration<int>();
      final current = generations.begin([7])[7]!;
      var published = false;

      expect(generations.publishIfCurrent(7, current, () => published = true), isTrue);
      expect(published, isTrue);
    });
  });

  group('input validation', () {
    test('portError rejects empty, non-numeric and out-of-range values', () {
      expect(portError('22'), isNull);
      expect(portError(' 65535 '), isNull);
      expect(portError(''), 'Required');
      expect(portError('   '), 'Required');
      expect(portError('abc'), 'Must be a whole number');
      expect(portError('22.5'), 'Must be a whole number');
      // 0 is "any port" to the kernel and never what a user means here.
      expect(portError('0'), 'Must be 1-65535');
      expect(portError('65536'), 'Must be 1-65535');
      expect(portError('-1'), 'Must be 1-65535');
    });

    test('countError honours its bounds', () {
      expect(countError('1'), isNull);
      expect(countError('0'), 'Must be 1-9999');
      expect(countError('5', min: 10, max: 20), 'Must be 10-20');
      expect(countError('15', min: 10, max: 20), isNull);
      expect(countError(''), 'Required');
      expect(countError('x'), 'Must be a whole number');
    });

    test('percentError accepts 0-100 and rejects non-finite input', () {
      expect(percentError('0'), isNull);
      expect(percentError('100'), isNull);
      expect(percentError('55.5'), isNull);
      expect(percentError(''), 'Required');
      expect(percentError('abc'), 'Must be a number');
      expect(percentError('-0.1'), 'Must be 0 or more');
      expect(percentError('100.1'), 'Must be 100 or less');
      // double.tryParse accepts these, so the isFinite guard is what rejects them.
      expect(percentError('Infinity'), 'Must be a number');
      expect(percentError('NaN'), 'Must be a number');
    });

    test('macAddressError accepts colon and hyphen forms', () {
      expect(macAddressError('AA:BB:CC:DD:EE:FF'), isNull);
      expect(macAddressError('aa-bb-cc-dd-ee-ff'), isNull);
      expect(macAddressError(' AA:BB:CC:DD:EE:FF '), isNull);
    });

    test('macAddressError rejects malformed addresses', () {
      const invalid = 'Use the form AA:BB:CC:DD:EE:FF';
      expect(macAddressError(''), 'Required');
      expect(macAddressError('AA:BB:CC:DD:EE'), invalid, reason: 'five octets');
      expect(macAddressError('AA:BB:CC:DD:EE:FF:00'), invalid, reason: 'seven octets');
      expect(macAddressError('AA:BB:CC:DD:EE:GG'), invalid, reason: 'G is not hex');
      expect(macAddressError('A:BB:CC:DD:EE:FF'), invalid, reason: 'octets must be two digits');
      // int.tryParse(radix: 16) would accept a signed octet; the digit check must not.
      expect(macAddressError('+A:BB:CC:DD:EE:FF'), invalid);
      expect(macAddressError('-1:BB:CC:DD:EE:FF'), invalid);
    });
  });

  group('measurement units', () {
    test('imperial temperature round-trips through canonical Celsius storage', () {
      final fahrenheit = celsiusToDisplay(65, MeasurementSystem.imperial);
      expect(fahrenheit, closeTo(149, 0.001));
      expect(
        displayTemperatureToCelsius(fahrenheit, MeasurementSystem.imperial),
        closeTo(65, 0.001),
      );
    });

    test('formatting uses the selected measurement system', () {
      expect(
        formatTemperature(75, MeasurementSystem.metric, decimals: 1, locale: 'en_US'),
        '75.0°C',
      );
      expect(
        formatTemperature(75, MeasurementSystem.imperial, decimals: 1, locale: 'en_US'),
        '167.0°F',
      );
      expect(temperatureUnit(MeasurementSystem.imperial), '°F');
    });

    test('the decimal separator follows the locale, as Locale.getDefault() did', () {
      // German uses a comma; this is why formatTemperature does not force Locale.US the way
      // humanBytes does.
      expect(
        formatTemperature(21.5, MeasurementSystem.metric, decimals: 1, locale: 'de_DE'),
        '21,5°C',
      );
    });

    test('zero decimals emits no separator at all', () {
      expect(formatTemperature(21.5, MeasurementSystem.metric, locale: 'de_DE'), '22°C');
    });

    test('the persisted setting value round-trips', () {
      expect(MeasurementSystem.fromSetting('imperial'), MeasurementSystem.imperial);
      expect(MeasurementSystem.fromSetting('metric'), MeasurementSystem.metric);
      expect(MeasurementSystem.fromSetting(null), MeasurementSystem.metric);
      expect(MeasurementSystem.fromSetting('nonsense'), MeasurementSystem.metric);
    });
  });

  group('app lock timeout', () {
    test('normalize clamps to the supported range', () {
      expect(normalizeAppLockBackgroundTimeout(null), defaultAppLockBackgroundTimeoutMs);
      expect(normalizeAppLockBackgroundTimeout(-5), 0);
      expect(normalizeAppLockBackgroundTimeout(60000), 60000);
      expect(
        normalizeAppLockBackgroundTimeout(maxAppLockBackgroundTimeoutMs + 1),
        maxAppLockBackgroundTimeoutMs,
      );
    });

    test('a configuration change is not a background event', () {
      expect(shouldRecordAppBackground(isChangingConfigurations: true), isFalse);
      expect(shouldRecordAppBackground(isChangingConfigurations: false), isTrue);
    });

    test('a preset timeout is not flagged as custom', () {
      expect(AppLockTimeoutDraft.fromTimeout(30000).customSelected, isFalse);
      expect(AppLockTimeoutDraft.fromTimeout(0).customSelected, isFalse);
      expect(AppLockTimeoutDraft.fromTimeout(300000).customSelected, isFalse);
      expect(AppLockTimeoutDraft.fromTimeout(45000).customSelected, isTrue);
    });

    test('a custom timeout is decomposed into the largest whole unit', () {
      final hours = AppLockTimeoutDraft.fromTimeout(2 * 3600000);
      expect((hours.customValue, hours.customUnit), ('2', 'Hours'));

      final minutes = AppLockTimeoutDraft.fromTimeout(10 * 60000);
      expect((minutes.customValue, minutes.customUnit), ('10', 'Minutes'));

      final seconds = AppLockTimeoutDraft.fromTimeout(45000);
      expect((seconds.customValue, seconds.customUnit), ('45', 'Seconds'));
    });

    test('selecting custom seeds ten minutes but never re-seeds', () {
      final draft = AppLockTimeoutDraft.fromTimeout(0).selectCustom();
      expect(draft.customSelected, isTrue);
      expect(draft.timeoutMs, 10 * 60000);

      final edited = draft.editCustomValue('45').selectCustom();
      expect(edited.customValue, '45', reason: 're-selecting must not wipe a half-typed entry');
    });

    test('editing keeps digits only, capped at five characters', () {
      final draft = AppLockTimeoutDraft.fromTimeout(0).selectCustom();
      expect(draft.editCustomValue('12a3').customValue, '123');
      expect(draft.editCustomValue('1234567').customValue, '12345');
      expect(draft.editCustomValue('  9 ').customValue, '9');
    });

    test('an unparseable entry leaves the committed timeout untouched', () {
      final draft = AppLockTimeoutDraft.fromTimeout(60000).selectCustom();
      final cleared = draft.editCustomValue('');
      expect(cleared.customValue, '');
      expect(cleared.timeoutMs, draft.timeoutMs, reason: 'clearing mid-edit must not change it');
      expect(cleared.isValid, isFalse);
    });

    test('a custom duration beyond 24 hours is rejected', () {
      expect(parseAppLockCustomDuration('24', 'Hours'), maxAppLockBackgroundTimeoutMs);
      expect(parseAppLockCustomDuration('25', 'Hours'), isNull);
      expect(parseAppLockCustomDuration('0', 'Minutes'), isNull);
      expect(parseAppLockCustomDuration('5', 'Fortnights'), isNull);
    });

    test('changing the unit recomputes the timeout', () {
      final draft = AppLockTimeoutDraft.fromTimeout(0).selectCustom().editCustomValue('2');
      expect(draft.selectCustomUnit('Hours').timeoutMs, 2 * 3600000);
      expect(draft.selectCustomUnit('Seconds').timeoutMs, 2000);
    });

    group('AppLockTimeoutTracker', () {
      test('re-locks once the configured interval has elapsed', () {
        final t = AppLockTimeoutTracker()..noteBackgrounded(1000);
        expect(
          t.consumeShouldRelock(
            nowMs: 1000 + 30000,
            timeoutMs: 30000,
            lockEnabled: true,
            hasPin: true,
          ),
          isTrue,
        );
      });

      test('does not re-lock before the interval', () {
        final t = AppLockTimeoutTracker()..noteBackgrounded(1000);
        expect(
          t.consumeShouldRelock(
            nowMs: 1000 + 29999,
            timeoutMs: 30000,
            lockEnabled: true,
            hasPin: true,
          ),
          isFalse,
        );
      });

      test('duplicate lifecycle callbacks keep the earliest stop', () {
        final t = AppLockTimeoutTracker()
          ..noteBackgrounded(1000)
          ..noteBackgrounded(20000);
        expect(
          t.consumeShouldRelock(nowMs: 31000, timeoutMs: 30000, lockEnabled: true, hasPin: true),
          isTrue,
          reason: 'the later callback must not restart the interval',
        );
      });

      test('never re-locks without a pin or with locking disabled', () {
        final a = AppLockTimeoutTracker()..noteBackgrounded(0);
        expect(
          a.consumeShouldRelock(nowMs: 999999, timeoutMs: 30000, lockEnabled: false, hasPin: true),
          isFalse,
        );
        final b = AppLockTimeoutTracker()..noteBackgrounded(0);
        expect(
          b.consumeShouldRelock(nowMs: 999999, timeoutMs: 30000, lockEnabled: true, hasPin: false),
          isFalse,
        );
      });

      test('the pending timestamp is consumed, so it cannot fire twice', () {
        final t = AppLockTimeoutTracker()..noteBackgrounded(0);
        expect(
          t.consumeShouldRelock(nowMs: 60000, timeoutMs: 30000, lockEnabled: true, hasPin: true),
          isTrue,
        );
        expect(
          t.consumeShouldRelock(nowMs: 120000, timeoutMs: 30000, lockEnabled: true, hasPin: true),
          isFalse,
          reason: 'a stale timestamp must not survive to lock a later resume',
        );
      });

      test('a stale timestamp is consumed even when locking is disabled', () {
        final t = AppLockTimeoutTracker()..noteBackgrounded(0);
        t.consumeShouldRelock(nowMs: 60000, timeoutMs: 30000, lockEnabled: false, hasPin: true);
        expect(
          t.consumeShouldRelock(nowMs: 120000, timeoutMs: 30000, lockEnabled: true, hasPin: true),
          isFalse,
        );
      });

      test('clear discards a pending background', () {
        final t = AppLockTimeoutTracker()
          ..noteBackgrounded(0)
          ..clear();
        expect(
          t.consumeShouldRelock(nowMs: 999999, timeoutMs: 30000, lockEnabled: true, hasPin: true),
          isFalse,
        );
      });

      test('a backwards clock does not force a lock', () {
        final t = AppLockTimeoutTracker()..noteBackgrounded(100000);
        expect(
          t.consumeShouldRelock(nowMs: 1000, timeoutMs: 30000, lockEnabled: true, hasPin: true),
          isFalse,
        );
      });
    });
  });

  group('TerminalKeyEncoder', () {
    Uint8List enc(
      TermKey key, {
      bool app = false,
      bool shift = false,
      bool alt = false,
      bool ctrl = false,
    }) => TerminalKeyEncoder.encode(
      key,
      applicationCursorKeys: app,
      shift: shift,
      alt: alt,
      ctrl: ctrl,
    );

    test('cursor keys use CSI normally and SS3 in application mode', () {
      expect(enc(TermKey.up), Uint8List.fromList([0x1B, 0x5B, 0x41])); // ESC [ A
      expect(enc(TermKey.up, app: true), Uint8List.fromList([0x1B, 0x4F, 0x41])); // ESC O A
      expect(enc(TermKey.down), Uint8List.fromList([0x1B, 0x5B, 0x42]));
      expect(enc(TermKey.right), Uint8List.fromList([0x1B, 0x5B, 0x43]));
      expect(enc(TermKey.left), Uint8List.fromList([0x1B, 0x5B, 0x44]));
    });

    test('a modified cursor key always uses the CSI form with a modifier parameter', () {
      // Even in application mode, which is what xterm itself does.
      expect(String.fromCharCodes(enc(TermKey.up, shift: true)), '[1;2A');
      expect(String.fromCharCodes(enc(TermKey.up, alt: true)), '[1;3A');
      expect(String.fromCharCodes(enc(TermKey.up, ctrl: true)), '[1;5A');
      expect(String.fromCharCodes(enc(TermKey.up, app: true, ctrl: true)), '[1;5A');
      expect(String.fromCharCodes(enc(TermKey.up, shift: true, alt: true, ctrl: true)), '[1;8A');
    });

    test('enter, backspace and esc gain an ESC prefix under Alt', () {
      expect(enc(TermKey.enter), Uint8List.fromList([0x0D]));
      expect(enc(TermKey.enter, alt: true), Uint8List.fromList([0x1B, 0x0D]));
      expect(enc(TermKey.backspace), Uint8List.fromList([0x7F]));
      expect(enc(TermKey.backspace, alt: true), Uint8List.fromList([0x1B, 0x7F]));
      expect(enc(TermKey.esc), Uint8List.fromList([0x1B]));
      expect(enc(TermKey.esc, alt: true), Uint8List.fromList([0x1B, 0x1B]));
    });

    test('tab is plain, back-tab under Shift, ESC-prefixed under Alt', () {
      expect(enc(TermKey.tab), Uint8List.fromList([0x09]));
      expect(String.fromCharCodes(enc(TermKey.tab, shift: true)), '[Z');
      expect(enc(TermKey.tab, alt: true), Uint8List.fromList([0x1B, 0x09]));
    });

    test('editing and paging keys use the tilde form', () {
      expect(String.fromCharCodes(enc(TermKey.insert)), '[2~');
      expect(String.fromCharCodes(enc(TermKey.delete)), '[3~');
      expect(String.fromCharCodes(enc(TermKey.pageUp)), '[5~');
      expect(String.fromCharCodes(enc(TermKey.pageDown)), '[6~');
      expect(String.fromCharCodes(enc(TermKey.pageUp, ctrl: true)), '[5;5~');
    });

    test('F1-F4 use SS3 and the rest use the tilde form', () {
      expect(String.fromCharCodes(enc(TermKey.f1)), 'OP');
      expect(String.fromCharCodes(enc(TermKey.f4)), 'OS');
      expect(String.fromCharCodes(enc(TermKey.f1, shift: true)), '[1;2P');
      expect(String.fromCharCodes(enc(TermKey.f5)), '[15~');
      expect(String.fromCharCodes(enc(TermKey.f12)), '[24~');
      // The gaps are real: xterm skips 16 and 22.
      expect(String.fromCharCodes(enc(TermKey.f6)), '[17~');
      expect(String.fromCharCodes(enc(TermKey.f11)), '[23~');
    });

    test('every key encodes to a non-empty sequence', () {
      for (final key in TermKey.values) {
        expect(enc(key), isNotEmpty, reason: '$key');
      }
    });

    test('controlByte maps the standard Ctrl chords', () {
      expect(TerminalKeyEncoder.controlByte('a'.codeUnitAt(0)), 0x01);
      expect(TerminalKeyEncoder.controlByte('A'.codeUnitAt(0)), 0x01);
      expect(TerminalKeyEncoder.controlByte('c'.codeUnitAt(0)), 0x03);
      expect(TerminalKeyEncoder.controlByte('z'.codeUnitAt(0)), 0x1A);
      expect(TerminalKeyEncoder.controlByte(' '.codeUnitAt(0)), 0x00);
      expect(TerminalKeyEncoder.controlByte('@'.codeUnitAt(0)), 0x00);
      expect(TerminalKeyEncoder.controlByte('2'.codeUnitAt(0)), 0x00);
      expect(TerminalKeyEncoder.controlByte('['.codeUnitAt(0)), 0x1B);
      expect(TerminalKeyEncoder.controlByte(r'\'.codeUnitAt(0)), 0x1C);
      expect(TerminalKeyEncoder.controlByte(']'.codeUnitAt(0)), 0x1D);
      expect(TerminalKeyEncoder.controlByte('^'.codeUnitAt(0)), 0x1E);
      expect(TerminalKeyEncoder.controlByte('6'.codeUnitAt(0)), 0x1E);
      expect(TerminalKeyEncoder.controlByte('_'.codeUnitAt(0)), 0x1F);
      expect(TerminalKeyEncoder.controlByte('/'.codeUnitAt(0)), 0x1F);
      expect(TerminalKeyEncoder.controlByte('?'.codeUnitAt(0)), 0x7F);
      expect(TerminalKeyEncoder.controlByte('1'.codeUnitAt(0)), isNull);
    });

    test('only paging is allowed while read-only', () {
      expect(terminalKeyAllowedInReadOnly(TermKey.pageUp), isTrue);
      expect(terminalKeyAllowedInReadOnly(TermKey.pageDown), isTrue);
      for (final key in TermKey.values) {
        if (key == TermKey.pageUp || key == TermKey.pageDown) continue;
        expect(terminalKeyAllowedInReadOnly(key), isFalse, reason: '$key');
      }
    });
  });

  group('script filters', () {
    test('systemPlatformKey collapses display names to probe keys', () {
      expect(systemPlatformKey('Home Assistant'), 'homeassistant');
      expect(systemPlatformKey('Raspberry Pi'), 'raspberry');
      expect(systemPlatformKey('Proxmox'), 'proxmox');
      expect(systemPlatformKey('CasaOS'), 'casaos');
    });

    test('legacyCategoryPlatformKey only claims the known categories', () {
      expect(legacyCategoryPlatformKey('Proxmox'), 'proxmox');
      expect(legacyCategoryPlatformKey('Home Assistant'), 'homeassistant');
      expect(legacyCategoryPlatformKey('Raspberry Pi'), 'raspberry');
      // A user-made category must not filter anything out.
      expect(legacyCategoryPlatformKey('Backups'), isNull);
      expect(legacyCategoryPlatformKey('General'), isNull);
    });

    test('the option lists are the ones the pickers offer', () {
      expect(quickScriptOsOptions.first, 'Any');
      expect(quickScriptSystemOptions.first, 'Any');
      expect(quickScriptSystemOptions, contains('Home Assistant'));
    });
  });

  /// Opening a binary in the text editor. Hardening rather than a Kotlin port: Kotlin has only a
  /// *size* guard.
  ///
  /// The editor is handed an already-decoded string, because the SFTP client reads with
  /// `utf8.decode(..., allowMalformed: true)` — so invalid bytes have already become U+FFFD before
  /// anything here sees them. That is invisible on screen (the replacement character renders as an
  /// ordinary glyph) and saving writes those three bytes over the original, corrupting the file.
  group('binaryEditWarning', () {
    test('ordinary text is safe', () {
      expect(binaryEditWarning('#!/bin/sh\nexec true\n'), isNull);
    });

    test('valid multi-byte UTF-8 is still safe', () {
      // Accents and emoji decode cleanly and must not be mistaken for damage.
      expect(binaryEditWarning('cafeé — naiïve \u{1F680}'), isNull);
    });

    test('a NUL byte is reported as binary', () {
      final warning = binaryEditWarning('MZ\u0000\u0000program');
      expect(warning, isNotNull);
      expect(warning, contains('NUL'));
      expect(warning, contains('corrupt'));
    });

    test('replacement characters are reported as a lossy read', () {
      // What a latin-1 or truly binary file looks like after allowMalformed decoding.
      final warning = binaryEditWarning('caf\uFFFD data');
      expect(warning, isNotNull);
      expect(warning, contains('not valid UTF-8'));
      expect(
        warning,
        contains('over the original bytes'),
        reason: 'the user must be told saving destroys data, not merely that it looks odd',
      );
    });

    test('NUL takes precedence over a replacement character', () {
      // Both present: "this is a binary" is the more useful thing to say.
      expect(binaryEditWarning('\u0000\uFFFD'), contains('NUL'));
    });

    test('an empty file is safe', () {
      expect(binaryEditWarning(''), isNull);
    });
  });
}
