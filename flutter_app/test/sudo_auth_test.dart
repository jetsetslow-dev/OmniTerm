import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_pin.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';

import 'support/fake_secure_storage.dart';

/// The check before every sudo action: App Lock when it is on, else the phone's own lock, else a
/// plain question. Ported from `withSudoAuth` / `verifyPinForSensitiveAction` (`ui/AppViewModel.kt`).
/// A plain "are you sure?" asks about intent rather than identity, so anyone holding the unlocked
/// phone could otherwise reboot a server or stop `sshd`.
void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
  });

  tearDown(() => db.close());

  Future<AppLockController> controller({
    String? pin = '1234',
    bool biometrics = false,
    BiometricPrompt? prompt,
  }) async {
    if (pin != null) await repo.insertSetting('app_pin', pin);
    await repo.insertSetting('app_lock_enabled', 'true');
    await repo.insertSetting('biometrics_enabled', '$biometrics');
    final lock = AppLockController(repo, biometricPrompt: prompt);
    await lock.load();
    return lock;
  }

  group('which check a sudo action asks for', () {
    // Every sudo action asks, saved password or not (Kotlin's `withSudoAuth`). What it asks for
    // follows what the phone can check.
    test('App Lock with a PIN asks for App Lock', () async {
      final lock = await controller();
      expect(lock.sudoAuthUsesAppLock, isTrue);
      lock.dispose();
    });

    test('without App Lock it asks for the phone lock, when there is one', () async {
      final asked = <String>[];
      await repo.insertSetting('app_lock_enabled', 'false');
      final lock = AppLockController(
        repo,
        deviceLockAvailable: () async => true,
        deviceLockPrompt: (title, subtitle) async {
          asked.add('$title / $subtitle');
          return true;
        },
      );
      await lock.load();

      expect(lock.sudoAuthUsesAppLock, isFalse);
      expect(await lock.hasDeviceLock(), isTrue);
      expect(await lock.authenticateWithDeviceLock('Authenticate for sudo', 'Run this?'), isTrue);
      expect(asked, ['Authenticate for sudo / Run this?']);
      lock.dispose();
    });

    test('no App Lock and no phone lock leaves the plain question', () async {
      await repo.insertSetting('app_lock_enabled', 'false');
      final lock = AppLockController(
        repo,
        deviceLockAvailable: () async => false,
        deviceLockPrompt: (_, _) async => true,
      );
      await lock.load();

      expect(lock.sudoAuthUsesAppLock, isFalse);
      expect(await lock.hasDeviceLock(), isFalse);
      lock.dispose();
    });

    test(
      'a phone lock check that throws counts as no lock, and a throwing prompt as a no',
      () async {
        await repo.insertSetting('app_lock_enabled', 'false');
        final lock = AppLockController(
          repo,
          deviceLockAvailable: () async => throw StateError('no keyguard'),
          deviceLockPrompt: (_, _) async => throw StateError('cancelled'),
        );
        await lock.load();

        expect(await lock.hasDeviceLock(), isFalse);
        expect(await lock.authenticateWithDeviceLock('t', 's'), isFalse);
        lock.dispose();
      },
    );
  });

  group('verifyPinForSensitiveAction', () {
    test('the right PIN passes without unlocking or locking the app', () async {
      final lock = await controller();
      final wasLocked = lock.isLocked;

      expect(await lock.verifyPinForSensitiveAction('1234'), isNull);
      expect(
        lock.isLocked,
        wasLocked,
        reason: 'verifying for an action must not change the app lock state',
      );
      lock.dispose();
    });

    test('a wrong PIN is refused with a reason', () async {
      final lock = await controller();
      expect(await lock.verifyPinForSensitiveAction('9999'), 'Incorrect PIN');
      lock.dispose();
    });

    test('it shares the lock screen throttle rather than having its own', () async {
      // A separate allowance here would be a way to brute-force the same PIN at full speed from a
      // different dialog.
      final lock = await controller();
      for (var i = 0; i < pinMaxAttempts; i++) {
        await lock.verifyPinForSensitiveAction('9999');
      }

      expect(lock.isThrottled, isTrue);
      expect(
        await lock.verifyPinForSensitiveAction('1234'),
        contains('wait'),
        reason: 'even the correct PIN waits out the throttle',
      );
      lock.dispose();
    });

    test('a hashed PIN verifies too', () async {
      await repo.insertSetting('app_pin', await hashPinForStorage('4321'));
      await repo.insertSetting('app_lock_enabled', 'true');
      final lock = AppLockController(repo);
      await lock.load();

      expect(await lock.verifyPinForSensitiveAction('4321'), isNull);
      lock.dispose();
    });
  });

  group('authenticateForSensitiveAction', () {
    test('a successful prompt passes without unlocking the app', () async {
      final lock = await controller(biometrics: true, prompt: (_) async => true);
      final wasLocked = lock.isLocked;

      expect(await lock.authenticateForSensitiveAction(), isTrue);
      expect(lock.isLocked, wasLocked);
      lock.dispose();
    });

    test('a refusal is not a lockout', () async {
      // The PIN is the authority; a reader that cannot read a wet finger must not consume attempts.
      final lock = await controller(biometrics: true, prompt: (_) async => false);

      expect(await lock.authenticateForSensitiveAction(), isFalse);
      expect(lock.isThrottled, isFalse);
      expect(lock.failedAttempts, 0);
      lock.dispose();
    });

    test('a throwing prompt is a refusal, not a crash', () async {
      final lock = await controller(
        biometrics: true,
        prompt: (_) async => throw StateError('no sensor'),
      );
      expect(await lock.authenticateForSensitiveAction(), isFalse);
      lock.dispose();
    });

    test('it refuses when biometrics are switched off', () async {
      final lock = await controller(prompt: (_) async => true);
      expect(await lock.authenticateForSensitiveAction(), isFalse);
      lock.dispose();
    });
  });
}
