import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_pin.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';

import 'support/fake_secure_storage.dart';

/// Re-authentication before a privileged action uses a **stored** sudo password.
///
/// Ported from `withSudoAuth` / `verifyPinForSensitiveAction` (`ui/AppViewModel.kt:2521`, `:3130`).
/// Flutter ran reboot and service actions behind a plain "are you sure?", which asks about intent
/// rather than identity — so on a host with a saved sudo password, anyone holding the unlocked phone
/// could reboot the server or stop `sshd`.
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

  group('requiresSudoAuth', () {
    test('a host with no stored sudo password is not gated', () async {
      // Nothing extra to protect: the user will be typing the password themselves.
      final lock = await controller();
      expect(lock.requiresSudoAuth(''), isFalse);
      expect(lock.requiresSudoAuth('   '), isFalse);
      lock.dispose();
    });

    test('a stored password with a PIN configured is gated', () async {
      final lock = await controller();
      expect(lock.requiresSudoAuth('hunter2'), isTrue);
      lock.dispose();
    });

    test('a stored password with no PIN and no biometrics is not gated', () async {
      // There is nothing to check the user against, so a prompt would be theatre.
      final lock = await controller(pin: null);
      expect(lock.requiresSudoAuth('hunter2'), isFalse);
      lock.dispose();
    });

    test('biometrics alone are enough to gate', () async {
      final lock = await controller(
        pin: null,
        biometrics: true,
        prompt: (_) async => true,
      );
      expect(lock.requiresSudoAuth('hunter2'), isTrue);
      lock.dispose();
    });
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
