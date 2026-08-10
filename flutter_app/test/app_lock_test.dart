import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_pin.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/widgets/app_lock_gate.dart';

import 'support/fake_secure_storage.dart';

void main() {
  group('PIN storage', () {
    test('a stored PIN is a salted hash, never the PIN itself', () async {
      final stored = await hashPinForStorage('1234');

      expect(stored, startsWith('pin:v2:'));
      expect(stored, isNot(contains('1234')));
      expect(await verifyStoredPin(stored, '1234'), isTrue);
      expect(await verifyStoredPin(stored, '1235'), isFalse);
    });

    test('the same PIN hashes differently every time', () async {
      // Without a per-PIN salt, one precomputed table covers every user of the app — and a
      // four-digit space is small enough to precompute over breakfast.
      expect(await hashPinForStorage('1234'), isNot(await hashPinForStorage('1234')));
    });

    test('the format matches what the Kotlin app wrote', () async {
      // Data compatibility: an upgraded install must keep the PIN its owner already set.
      final parts = (await hashPinForStorage('123456')).split(':');
      expect(parts, hasLength(6));
      expect(parts[0], 'pin');
      expect(parts[1], 'v2');
      expect(int.parse(parts[2]), pinPbkdf2Iterations);
      expect(parts.last, '6', reason: 'the length is recorded so the screen can size itself');
    });

    test('the recorded length does not reveal the PIN', () async {
      final stored = await hashPinForStorage('4821');
      expect(storedPinLength(stored), 4);
      expect(stored, isNot(contains('4821')));
    });

    group('a malformed record is a wrong PIN, never a crash', () {
      // This is the one screen standing between someone holding the phone and the host list. It has
      // to fail closed on every kind of nonsense rather than throwing its way open.
      for (final (name, stored) in const [
        ('truncated', 'pin:v2:210000:abc'),
        ('bad base64', 'pin:v2:210000:!!!!:!!!!:4'),
        ('empty', ''),
        ('unknown version', 'pin:v9:210000:AAAA:BBBB:4'),
        ('short salt', 'pin:v2:210000:AAAA:BBBB:4'),
      ]) {
        test(name, () async {
          expect(await verifyStoredPin(stored, '1234'), isFalse);
        });
      }

      test('null', () async {
        expect(await verifyStoredPin(null, '1234'), isFalse);
      });
    });

    test('a record naming an absurd work factor is refused', () async {
      // The stored row is not trusted to say how much work verification costs: 1 round makes an
      // offline attack free, and a billion hangs the unlock screen.
      final real = await hashPinForStorage('1234');
      final parts = real.split(':');
      final tampered = ['pin', 'v2', '1', parts[3], parts[4], parts[5]].join(':');
      final absurd = ['pin', 'v2', '999999999', parts[3], parts[4], parts[5]].join(':');

      expect(await verifyStoredPin(tampered, '1234'), isFalse);
      expect(await verifyStoredPin(absurd, '1234'), isFalse);
    });

    test('an old plaintext PIN still works, and is marked for upgrade', () async {
      // Getting an existing user in matters more than refusing their old record; the upgrade
      // happens on the one occasion the PIN is available in the clear.
      expect(await verifyStoredPin('1234', '1234'), isTrue);
      expect(pinNeedsRehash('1234'), isTrue);
      expect(pinNeedsRehash(await hashPinForStorage('1234')), isFalse);
    });

    test('an empty PIN never verifies', () async {
      expect(await verifyStoredPin(await hashPinForStorage('1234'), ''), isFalse);
      expect(await verifyStoredPin('', ''), isFalse);
    });

    test('throttling starts at the attempt limit', () {
      expect(pinLockoutAfterFailure(pinMaxAttempts - 1, 1000), 0);
      expect(pinLockoutAfterFailure(pinMaxAttempts, 1000), 1000 + pinLockoutMs);
      expect(isPinThrottled(5000, 4999), isTrue);
      expect(isPinThrottled(5000, 5000), isFalse);
    });
  });

  group('the lock', () {
    late AppDatabase db;
    late AppRepository repo;
    var now = 1000000;
    // A clock the user cannot set, advanced independently so a test can simulate the wall clock
    // being tampered with while real time keeps passing.
    var monotonic = 500000;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      now = 1000000;
      monotonic = 500000;
    });

    tearDown(() => db.close());

    AppLockController build({BiometricPrompt? biometrics}) => AppLockController(
      repo,
      biometricPrompt: biometrics,
      clock: () => now,
      monotonicClock: () => monotonic,
    );

    Future<void> configure({
      String pin = '1234',
      bool enabled = true,
      bool biometrics = false,
      int timeoutMs = 30000,
    }) async {
      await repo.insertSetting('app_pin', await hashPinForStorage(pin));
      await repo.insertSetting('app_lock_enabled', '$enabled');
      await repo.insertSetting('biometrics_enabled', '$biometrics');
      // The key the Android app writes. Named here rather than in a constant so a rename in the
      // controller cannot quietly take the tests with it — see the dedicated test below.
      await repo.insertSetting('app_lock_grace_ms', '$timeoutMs');
    }

    test('the interval is read from the key the Android app already wrote', () async {
      // A migrating install carries `app_lock_grace_ms`; reading any other key would silently put
      // every upgraded user back on the 30-second default while the screen still showed theirs.
      await repo.insertSetting('app_pin', await hashPinForStorage('1234'));
      await repo.insertSetting('app_lock_enabled', 'true');
      await repo.insertSetting('app_lock_grace_ms', '0');
      final lock = build();
      await lock.load();
      await lock.unlockWithPin('1234');

      lock.onBackgrounded();
      lock.onForegrounded();

      expect(lock.isLocked, isTrue, reason: 'a zero interval must lock on the way back');
      lock.dispose();
    });

    test('a cold start is locked when the lock is configured', () async {
      // Otherwise force-stopping the app — the easiest thing in the world to do to a phone you have
      // just picked up — is a way straight past the lock.
      await configure();
      final lock = build();
      await lock.load();

      expect(lock.isLocked, isTrue);
      lock.dispose();
    });

    test('an enabled lock with no PIN stays open', () async {
      // "Locked with no way to unlock" is not a security feature, it is a brick.
      await repo.insertSetting('app_lock_enabled', 'true');
      final lock = build();
      await lock.load();

      expect(lock.isConfigured, isFalse);
      expect(lock.isLocked, isFalse);
      lock.dispose();
    });

    test('an unconfigured app never locks', () async {
      final lock = build();
      await lock.load();
      lock.onBackgrounded();
      now += 600000;
      lock.onForegrounded();

      expect(lock.isLocked, isFalse);
      lock.dispose();
    });

    group('the background timer', () {
      test('a short absence does not lock', () async {
        await configure(timeoutMs: 30000);
        final lock = build();
        await lock.load();
        expect(await lock.unlockWithPin('1234'), UnlockOutcome.unlocked);

        lock.onBackgrounded();
        now += 10000;
        lock.onForegrounded();

        expect(lock.isLocked, isFalse);
        lock.dispose();
      });

      test('an absence past the timeout locks', () async {
        await configure(timeoutMs: 30000);
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('1234');

        lock.onBackgrounded();
        now += 31000;
        lock.onForegrounded();

        expect(lock.isLocked, isTrue);
        lock.dispose();
      });

      test('a zero timeout locks the moment the app is left', () async {
        // The setting that asks for the most protection must not be the only one that never fires.
        await configure(timeoutMs: 0);
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('1234');

        lock.onBackgrounded();
        lock.onForegrounded();

        expect(lock.isLocked, isTrue);
        lock.dispose();
      });

      /// The background timer must not be defeatable by moving the device clock.
      ///
      /// Kotlin uses `SystemClock.elapsedRealtime()` here and documents at `AppViewModel.kt:833`
      /// exactly why: a wall clock can be wound backwards to bypass the timeout, and
      /// `CLOCK_MONOTONIC` stops in deep sleep so the countdown freezes with the screen off. Dart
      /// has neither, so the controller takes the larger of the two elapsed times.
      group('clock tampering', () {
        test('winding the wall clock back does not prevent the lock', () async {
          await configure(timeoutMs: 30000);
          final lock = build();
          await lock.load();
          await lock.unlockWithPin('1234');

          lock.onBackgrounded();
          // A minute really passes, but the wall clock is moved an hour into the past.
          monotonic += 60000;
          now -= 3600000;
          lock.onForegrounded();

          expect(
            lock.isLocked,
            isTrue,
            reason: 'the timeout must not be bypassable by setting the clock back',
          );
          lock.dispose();
        });

        test('a frozen monotonic clock still locks via the wall clock', () async {
          // Deep sleep stops CLOCK_MONOTONIC. If that were the only source, the app would never
          // re-lock after the screen went off — the case Kotlin calls the one users hit most.
          await configure(timeoutMs: 30000);
          final lock = build();
          await lock.load();
          await lock.unlockWithPin('1234');

          lock.onBackgrounded();
          now += 600000; // ten minutes of wall clock
          // monotonic deliberately does not advance
          lock.onForegrounded();

          expect(lock.isLocked, isTrue);
          lock.dispose();
        });

        test('neither clock advancing leaves the app unlocked', () async {
          // The guard must not have become "always lock": returning immediately is ordinary use.
          await configure(timeoutMs: 30000);
          final lock = build();
          await lock.load();
          await lock.unlockWithPin('1234');

          lock.onBackgrounded();
          lock.onForegrounded();

          expect(lock.isLocked, isFalse);
          lock.dispose();
        });

        test('a backwards wall clock inside the timeout still does not lock', () async {
          await configure(timeoutMs: 30000);
          final lock = build();
          await lock.load();
          await lock.unlockWithPin('1234');

          lock.onBackgrounded();
          monotonic += 5000; // only five seconds really passed
          now -= 3600000;
          lock.onForegrounded();

          expect(
            lock.isLocked,
            isFalse,
            reason: 'a tampered clock must not make the lock fire early either',
          );
          lock.dispose();
        });
      });

      test('the real lifecycle sequence locks', () async {
        // The platform does not send one clean "backgrounded" event. Leaving is
        // `inactive` then `paused`, and *returning* is `inactive` then `resumed` — so the
        // controller sees a second `onBackgrounded` immediately before `onForegrounded`.
        // Assigning the timestamp there reset the clock microseconds before it was read, and the
        // lock never engaged at all. Found on a device; no host test replayed the real order.
        await configure(timeoutMs: 30000);
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('1234');

        lock.onBackgrounded(); // inactive, on the way out
        lock.onBackgrounded(); // paused
        now += 60000;
        lock.onBackgrounded(); // inactive, on the way back in
        lock.onForegrounded(); // resumed

        expect(lock.isLocked, isTrue);
        lock.dispose();
      });

      test('a return well inside the timeout still does not lock', () async {
        await configure(timeoutMs: 30000);
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('1234');

        lock.onBackgrounded();
        now += 5000;
        lock.onBackgrounded();
        lock.onForegrounded();

        expect(lock.isLocked, isFalse);
        lock.dispose();
      });

      test('a second absence is measured from its own start', () async {
        // The timestamp has to be cleared on return, or a short second trip would inherit the
        // first trip's age and lock immediately.
        await configure(timeoutMs: 30000);
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('1234');

        lock.onBackgrounded();
        now += 60000;
        lock.onForegrounded();
        expect(lock.isLocked, isTrue);

        await lock.unlockWithPin('1234');
        lock.onBackgrounded();
        now += 1000;
        lock.onForegrounded();

        expect(lock.isLocked, isFalse);
        lock.dispose();
      });

      test('a rotation is not the user leaving', () async {
        // Android re-creates the Activity on a configuration change; locking there would lock the
        // app when someone turned their phone sideways.
        await configure(timeoutMs: 0);
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('1234');

        lock.onBackgrounded(isChangingConfigurations: true);
        now += 600000;
        lock.onForegrounded();

        expect(lock.isLocked, isFalse);
        lock.dispose();
      });
    });

    group('unlocking', () {
      test('a wrong PIN is reported and counted', () async {
        await configure();
        final lock = build();
        await lock.load();

        expect(await lock.unlockWithPin('9999'), UnlockOutcome.wrongPin);
        expect(lock.isLocked, isTrue);
        expect(await repo.getSetting('pin_failed_attempts'), '1');
        lock.dispose();
      });

      test('repeated failures throttle', () async {
        await configure();
        final lock = build();
        await lock.load();

        for (var i = 0; i < pinMaxAttempts - 1; i++) {
          expect(await lock.unlockWithPin('9999'), UnlockOutcome.wrongPin);
        }
        expect(await lock.unlockWithPin('9999'), UnlockOutcome.throttled);
        expect(lock.isThrottled, isTrue);

        // Even the correct PIN waits out the lockout.
        expect(await lock.unlockWithPin('1234'), UnlockOutcome.throttled);
        expect(lock.isLocked, isTrue);

        now += pinLockoutMs + 1;
        expect(lock.isThrottled, isFalse);
        expect(await lock.unlockWithPin('1234'), UnlockOutcome.unlocked);
        lock.dispose();
      });

      test('the lockout survives a restart', () async {
        // The defect: only the attempt count was persisted, so force-stopping the app — the easiest
        // thing in the world to do to a phone you have picked up — cleared the wait. The throttle
        // then rate-limited nothing: restart, try one PIN, restart, try another.
        await configure();
        final first = build();
        await first.load();
        for (var i = 0; i < pinMaxAttempts; i++) {
          await first.unlockWithPin('9999');
        }
        expect(first.isThrottled, isTrue);
        first.dispose();

        final second = build();
        await second.load();

        expect(second.isThrottled, isTrue, reason: 'a force-stop is not a way past the throttle');
        expect(await second.unlockWithPin('1234'), UnlockOutcome.throttled);
        second.dispose();
      });

      test('a restart does not hand back a free attempt', () async {
        await configure();
        final first = build();
        await first.load();
        for (var i = 0; i < pinMaxAttempts; i++) {
          await first.unlockWithPin('9999');
        }
        first.dispose();

        final second = build();
        await second.load();
        // Even the right PIN waits: otherwise each restart is one more guess.
        expect(await second.unlockWithPin('1234'), UnlockOutcome.throttled);
        second.dispose();
      });

      test('a lockout that has already expired does not lock a fresh start', () async {
        await configure();
        await repo.insertSetting('pin_locked_until', '${now - 1}');
        final lock = build();
        await lock.load();

        expect(lock.isThrottled, isFalse);
        expect(await lock.unlockWithPin('1234'), UnlockOutcome.unlocked);
        lock.dispose();
      });

      test('a deadline far in the future is clamped rather than trusted', () async {
        // The deadline is wall-clock, and a device whose clock jumps forward would otherwise come
        // back locked for years — effectively bricked by a timezone change.
        await configure();
        await repo.insertSetting(
          'pin_locked_until',
          '${now + const Duration(days: 365).inMilliseconds}',
        );
        final lock = build();
        await lock.load();

        expect(lock.isThrottled, isTrue, reason: 'the throttle is still honoured');
        now += pinLockoutMs + 1;
        expect(lock.isThrottled, isFalse, reason: 'but never longer than one full lockout');
        lock.dispose();
      });

      test('unlocking clears the stored deadline', () async {
        await configure();
        final lock = build();
        await lock.load();
        for (var i = 0; i < pinMaxAttempts; i++) {
          await lock.unlockWithPin('9999');
        }
        now += pinLockoutMs + 1;
        expect(await lock.unlockWithPin('1234'), UnlockOutcome.unlocked);
        lock.dispose();

        final restarted = build();
        await restarted.load();
        expect(restarted.isThrottled, isFalse);
        restarted.dispose();
      });

      test('a success clears the failure count', () async {
        await configure();
        final lock = build();
        await lock.load();
        await lock.unlockWithPin('9999');

        expect(await lock.unlockWithPin('1234'), UnlockOutcome.unlocked);
        expect(await repo.getSetting('pin_failed_attempts'), '0');
        lock.dispose();
      });

      test('an old plaintext PIN is upgraded on the way in', () async {
        // The only moment the PIN exists in the clear is when the user has just typed it.
        await repo.insertSetting('app_pin', '1234');
        await repo.insertSetting('app_lock_enabled', 'true');
        final lock = build();
        await lock.load();

        expect(await lock.unlockWithPin('1234'), UnlockOutcome.unlocked);
        expect(await repo.getSetting('app_pin'), startsWith('pin:v2:'));
        lock.dispose();
      });

      test('biometrics unlock without touching the PIN throttle', () async {
        await configure(biometrics: true);
        final lock = build(biometrics: (_) async => true);
        await lock.load();

        expect(await lock.unlockWithBiometrics(), isTrue);
        expect(lock.isLocked, isFalse);
        lock.dispose();
      });

      test('a failed biometric read does not consume an attempt', () async {
        // A wet finger is not an intrusion, and burning attempts on it would push the user toward
        // the PIN and then lock them out of that too.
        await configure(biometrics: true);
        final lock = build(biometrics: (_) async => false);
        await lock.load();

        expect(await lock.unlockWithBiometrics(), isFalse);
        expect(lock.isLocked, isTrue);
        expect(lock.failedAttempts, 0);
        lock.dispose();
      });

      test('a throwing biometric prompt is a refusal, not a crash', () async {
        await configure(biometrics: true);
        final lock = build(biometrics: (_) async => throw StateError('no sensor'));
        await lock.load();

        expect(await lock.unlockWithBiometrics(), isFalse);
        lock.dispose();
      });

      test('biometrics are ignored when the setting is off', () async {
        await configure();
        final lock = build(biometrics: (_) async => true);
        await lock.load();

        expect(lock.canUseBiometrics, isFalse);
        expect(await lock.unlockWithBiometrics(), isFalse);
        expect(lock.isLocked, isTrue);
        lock.dispose();
      });

      test('with no biometric implementation the option is simply absent', () async {
        // Convention 4: no stub that reports success.
        await configure(biometrics: true);
        final lock = build();
        await lock.load();

        expect(lock.canUseBiometrics, isFalse);
        lock.dispose();
      });
    });

    group('configuration', () {
      test('setting a PIN enables the lock', () async {
        final lock = build();
        await lock.load();
        await lock.setPin('4321');

        expect(lock.isConfigured, isTrue);
        expect(await repo.getSetting('app_lock_enabled'), 'true');
        expect(await verifyStoredPin(await repo.getSetting('app_pin'), '4321'), isTrue);
        lock.dispose();
      });

      test('clearing forgets the PIN rather than leaving it behind', () async {
        // A stale hash would silently come back the next time the switch was flipped on.
        await configure();
        final lock = build();
        await lock.load();
        await lock.clearPin();

        expect(lock.isLocked, isFalse);
        expect(await repo.getSetting('app_pin'), isNull);
        expect(await repo.getSetting('biometrics_enabled'), 'false');
        lock.dispose();
      });

      test('refreshing does not lock a user out mid-session', () async {
        // Saving the Settings screen re-reads the configuration; it must not slam the door on the
        // person who just turned the setting on.
        final lock = build();
        await lock.load();
        await lock.setPin('1234');
        await lock.refresh();

        expect(lock.isLocked, isFalse);
        lock.dispose();
      });
    });
  });

  group('the lock screen', () {
    late AppDatabase db;
    late AppRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    });

    tearDown(() => db.close());

    /// Plain pumps rather than `pumpAndSettle`: once throttled the screen runs a one-second ticker
    /// to move the countdown, and settling waits for a timer that is meant to keep repeating.
    Future<void> settle(WidgetTester tester) async {
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<AppLockController> locked(WidgetTester tester, {BiometricPrompt? biometrics}) async {
      // A legacy plaintext PIN on purpose: these tests are about the screen, and a real PBKDF2
      // verification costs most of a second each, which a five-attempt throttle test multiplies
      // into a timeout. The hashed path has its own tests above.
      await repo.insertSetting('app_pin', '1234');
      await repo.insertSetting('app_lock_enabled', 'true');
      if (biometrics != null) {
        await repo.insertSetting('biometrics_enabled', 'true');
      }
      final lock = AppLockController(repo, biometricPrompt: biometrics);
      await lock.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: AppLockGate(
            controller: lock,
            child: const Scaffold(body: Text('the host list')),
          ),
        ),
      );
      await settle(tester);
      return lock;
    }

    /// Returning to a locked app must offer biometrics again.
    ///
    /// Leaving the app while the lock screen is up makes the platform cancel its biometric prompt.
    /// The lock screen is **not** rebuilt on the way back — the gate keeps it mounted for as long as
    /// the app is locked — so an `initState`-only trigger left the user staring at a bare PIN field.
    /// Kotlin re-prompts on every `ON_RESUME` for exactly this reason (`ui/AppUi.kt:724`).
    group('biometrics on resume', () {
      /// The real platform sequence. Flutter asserts on shortcuts, so every intermediate state has
      /// to be delivered: out is `inactive -> hidden -> paused`, back is
      /// `hidden -> inactive -> resumed`.
      Future<void> background(WidgetTester tester) async {
        for (final state in const [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await settle(tester);
      }

      Future<void> foreground(WidgetTester tester) async {
        for (final state in const [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await settle(tester);
      }

      testWidgets('a real backgrounding re-offers biometrics on return', (tester) async {
        var prompts = 0;
        final lock = await locked(
          tester,
          biometrics: (_) async {
            prompts++;
            return false;
          },
        );
        expect(prompts, 1, reason: 'offered once on entry');

        await background(tester);
        await foreground(tester);

        expect(prompts, 2, reason: 'the cancelled prompt must be re-offered on return');
        lock.dispose();
      });

      testWidgets('an inactive flicker does not re-prompt', (tester) async {
        // The biometric sheet itself can drive inactive -> resumed. Re-prompting on that would let a
        // cancelled prompt immediately raise another one.
        var prompts = 0;
        final lock = await locked(
          tester,
          biometrics: (_) async {
            prompts++;
            return false;
          },
        );

        // inactive -> resumed, with no paused in between: the app never actually left.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await settle(tester);

        expect(prompts, 1, reason: 'only a genuine backgrounding counts');
        lock.dispose();
      });

      testWidgets('a build without biometrics is never prompted on resume', (tester) async {
        final lock = await locked(tester);

        await background(tester);
        await foreground(tester);

        // Nothing to assert but the absence of a crash and the PIN field still being the way in.
        expect(find.byKey(const ValueKey('lock.pin')), findsOneWidget);
        expect(find.byKey(const ValueKey('lock.biometrics')), findsNothing);
        lock.dispose();
      });

      testWidgets('a successful biometric read on resume unlocks', (tester) async {
        var prompts = 0;
        final lock = await locked(
          tester,
          biometrics: (_) async {
            prompts++;
            // Refuse on entry, accept on the way back in.
            return prompts > 1;
          },
        );
        expect(find.byKey(const ValueKey('lock.screen')), findsOneWidget);

        await background(tester);
        await foreground(tester);

        expect(find.byKey(const ValueKey('lock.screen')), findsNothing);
        expect(find.text('the host list'), findsOneWidget);
        lock.dispose();
      });
    });

    testWidgets('covers the app until the right PIN is entered', (tester) async {
      final lock = await locked(tester);

      expect(find.byKey(const ValueKey('lock.screen')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('lock.pin')), '9999');
      await tester.tap(find.byKey(const ValueKey('lock.submit')));
      await settle(tester);
      expect(find.byKey(const ValueKey('lock.error')), findsOneWidget);
      expect(find.byKey(const ValueKey('lock.screen')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('lock.pin')), '1234');
      await tester.tap(find.byKey(const ValueKey('lock.submit')));
      await settle(tester);

      expect(find.byKey(const ValueKey('lock.screen')), findsNothing);
      expect(find.text('the host list'), findsOneWidget);
      lock.dispose();
    });

    testWidgets('a refused PIN hands the field back instead of dropping the keyboard', (
      tester,
    ) async {
      // The field is disabled while an attempt is verified, and disabling a TextField takes its
      // focus away. Without giving it back, every wrong PIN closes the keyboard and the user has
      // to tap the field again before they can retype — on the one screen where they are already
      // annoyed. (Found while automating the flow: `enterText` needs focus, so an unfocused field
      // swallowed the retry silently.)
      final lock = await locked(tester);

      await tester.enterText(find.byKey(const ValueKey('lock.pin')), '9999');
      await tester.tap(find.byKey(const ValueKey('lock.submit')));
      await settle(tester);

      expect(find.byKey(const ValueKey('lock.error')), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('lock.pin')));
      expect(field.focusNode?.hasFocus, isTrue, reason: 'the user is about to type again');
      lock.dispose();
    });

    testWidgets('the app underneath is not reachable while locked', (tester) async {
      // Hidden is not enough: a screen reader must not be able to walk the host list either.
      final lock = await locked(tester);

      final guard = find.ancestor(
        of: find.text('the host list'),
        matching: find.byType(ExcludeSemantics),
      );
      expect(guard, findsWidgets, reason: 'the app below the lock is out of the semantics tree');
      expect(tester.widgetList<ExcludeSemantics>(guard).any((w) => w.excluding), isTrue);
      expect(
        find.ancestor(of: find.text('the host list'), matching: find.byType(ExcludeFocus)),
        findsWidgets,
      );
      lock.dispose();
    });

    testWidgets('the biometric option appears only when it can work', (tester) async {
      final withOut = await locked(tester);
      expect(find.byKey(const ValueKey('lock.biometrics')), findsNothing);
      withOut.dispose();

      final withIt = await locked(tester, biometrics: (_) async => false);
      await settle(tester);
      expect(find.byKey(const ValueKey('lock.biometrics')), findsOneWidget);
      withIt.dispose();
    });

    testWidgets('biometrics are offered without being asked for', (tester) async {
      // Not having to type is the whole reason the option exists.
      var asked = 0;
      final lock = await locked(
        tester,
        biometrics: (_) async {
          asked++;
          return true;
        },
      );
      await settle(tester);

      expect(asked, 1);
      expect(find.byKey(const ValueKey('lock.screen')), findsNothing);
      lock.dispose();
    });

    testWidgets('the throttle disables entry and says how long', (tester) async {
      final lock = await locked(tester);

      for (var i = 0; i < pinMaxAttempts; i++) {
        await tester.enterText(find.byKey(const ValueKey('lock.pin')), '9999');
        await tester.tap(find.byKey(const ValueKey('lock.submit')));
        // Plain pumps rather than `pumpAndSettle`: once throttled the screen runs a one-second
        // ticker to move the countdown, and settling waits for a timer that is meant to repeat.
        await settle(tester);
      }

      expect(find.byKey(const ValueKey('lock.throttled')), findsOneWidget);
      final submit = tester.widget<FilledButton>(find.byKey(const ValueKey('lock.submit')));
      expect(submit.onPressed, isNull);
      lock.dispose();
    });

    testWidgets('it says plainly that there is no recovery', (tester) async {
      // Nothing this screen could offer would help a user that an attacker holding the phone could
      // not also use, so a dead-end "forgot your PIN?" would be worse than the truth.
      final lock = await locked(tester);
      expect(find.textContaining('no PIN recovery'), findsOneWidget);
      lock.dispose();
    });
  });
}
