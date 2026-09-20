import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/biometric_auth.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/widgets/app_lock_gate.dart';

import '../../test/support/fake_secure_storage.dart';

const _lifecycle = MethodChannel('omniterm/test/activity_lifecycle');

void main() {
  patrolTest(
    'biometric prompt survives real Activity recreation; cancel preserves PIN fallback',
    ($) async {
      $.tester.binding.platformDispatcher.semanticsEnabledTestValue = false;
      final database = AppDatabase(NativeDatabase.memory());
      final repository = AppRepository(database, SecretStore(storage: FakeSecureStorage({})));
      final auth = BiometricAuth();
      final lock = AppLockController(
        repository,
        biometricPrompt: auth.prompt,
        biometricAvailability: auth.isAvailable,
      );
      await $.tester.runAsync(() async {
        await repository.insertSetting('app_pin', '246810');
        await repository.insertSetting('app_lock_enabled', 'true');
        await repository.insertSetting('biometrics_enabled', 'true');
        await lock.load();
      });
      await $.tester.pumpWidget(
        MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: AppLockGate(
            controller: lock,
            child: const Scaffold(body: Text('Unlocked fixture')),
          ),
        ),
      );
      addTearDown(() async {
        await const MethodChannel('omniterm/biometrics').invokeMethod<void>('cancel');
        await $.tester.pumpWidget(const SizedBox.shrink());
        lock.dispose();
        await database.close();
      });
      expect(
        await _lifecycle.invokeMethod<bool>('biometricBranding'),
        isTrue,
        reason:
            'SystemUI must receive Kotlin’s bitmap branding, not an adaptive/default Flutter icon',
      );

      if (lock.biometricsAvailable) {
        final original = await _waitForRequest($);
        final duplicates = List.generate(3, (_) => lock.unlockWithBiometrics());
        expect(await _lifecycle.invokeMethod<int>('biometricRequestId'), original);
        final evidence = await _lifecycle.invokeMapMethod<String, dynamic>('recreate');
        expect(evidence?['destroyed'], isTrue);
        expect(evidence?['sameEngine'], isTrue);
        expect(
          await _waitForRequest($),
          original,
          reason: 'Recreation must keep the same cryptographic system authentication',
        );
        await $.platformAutomator.android.pressBack();
        await _waitForIdle($);
        expect(await Future.wait(duplicates), everyElement(isFalse));
        expect(lock.isLocked, isTrue);
        expect(lock.failedAttempts, 0);

        // Drive the visible control after a cancellation; it must open exactly one fresh prompt.
        // Native authentication keeps the visible busy indicator animating until it resolves;
        // do not ask Patrol to settle that animation before we can dismiss the system prompt.
        await $.tester.tap(find.byKey(const ValueKey('lock.biometrics')));
        await $.tester.pump();
        expect(await _waitForRequest($), isNot(original));
        await $.platformAutomator.android.pressBack();
        await _waitForIdle($);
        expect(lock.isLocked, isTrue);
      } else {
        await _until($, () => lock.biometricError != null);
        expect(lock.biometricError, contains('strong biometric'));
        debugPrint(
          'No enrolled strong biometric: native recreation branch requires enrolled fixture',
        );
      }

      await $.tester.enterText(find.byKey(const ValueKey('lock.pin')), '999999');
      await $.tester.pump();
      await $.tester.tap(find.byKey(const ValueKey('lock.submit')));
      await _until($, () => find.text('Incorrect PIN — try again').evaluate().isNotEmpty);
      expect(lock.isLocked, isTrue);
      await $.tester.enterText(find.byKey(const ValueKey('lock.pin')), '246810');
      await $.tester.pump();
      await $.tester.tap(find.byKey(const ValueKey('lock.submit')));
      await _until($, () => !lock.isLocked);
      expect(find.text('Unlocked fixture'), findsOneWidget);
    },
    semanticsEnabled: false,
    skip: !Platform.isAndroid,
  );

  final binding = WidgetsBinding.instance;
  binding.platformDispatcher.onSemanticsEnabledChanged = () {};
  final semantics = binding.ensureSemantics();
  tearDownAll(semantics.dispose);
}

Future<void> _until(PatrolIntegrationTester $, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue, reason: 'The authentication state did not finish changing');
}

Future<int> _waitForRequest(PatrolIntegrationTester $) async {
  int? request;
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (request == null && DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 50));
    request = await _lifecycle.invokeMethod<int>('biometricRequestId');
    if (request == null) await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(request, isNotNull, reason: 'The system fingerprint prompt did not start');
  return request!;
}

Future<void> _waitForIdle(PatrolIntegrationTester $) async {
  await _until(
    $,
    () => $.tester.widget<TextField>(find.byKey(const ValueKey('lock.pin'))).enabled == true,
  );
  expect(
    await _lifecycle.invokeMethod<int>('biometricRequestId'),
    isNull,
    reason: 'Cancellation must not trigger another auto-prompt',
  );
}
