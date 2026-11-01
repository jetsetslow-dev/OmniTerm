import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/domain/biometric_failure.dart';
import 'package:omniterm/platform/biometric_auth.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Kotlin-compatible biometric gate reports availability and cancels cleanly',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Biometric gate'))));
      final auth = BiometricAuth();
      final available = await auth.isAvailable();
      var completed = false;
      BiometricFailure? failure;
      final attempt = auth
          .prompt('Unlock OmniTerm')
          .catchError((Object error) {
            if (error is! BiometricFailure) throw error;
            failure = error;
            return false;
          })
          .whenComplete(() => completed = true);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!completed && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (available) {
        expect(completed, isFalse, reason: 'An enrolled device must wait for the real prompt');
        await const MethodChannel('omniterm/biometrics').invokeMethod<void>('cancel');
        expect(await attempt.timeout(const Duration(seconds: 10)), isFalse);
        expect(failure, isNull);
      } else {
        expect(await attempt.timeout(const Duration(seconds: 10)), isFalse);
        expect(failure?.message, contains('strong biometric'));
      }
    },
    skip: !Platform.isAndroid,
  );

  // Explicit hardware fixture: run with --dart-define=OMNITERM_E2E_BIOMETRICS=true on an emulator
  // with fingerprint 1 enrolled. The external driver observes the actual system authentication
  // session before sending `adb emu finger touch 1`. A clean CI device runs the guard above only.
  if (const bool.fromEnvironment('OMNITERM_E2E_BIOMETRICS')) {
    testWidgets('an enrolled fingerprint completes the real Keystore challenge', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Biometric success'))));
      final auth = BiometricAuth();
      expect(await auth.isAvailable(), isTrue, reason: 'Enroll a strong biometric on the fixture');
      var completed = false;
      final attempt = auth.prompt('Unlock OmniTerm').whenComplete(() => completed = true);
      debugPrint('OMNITERM_BIOMETRIC_TOUCH_READY');
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!completed && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!completed) await const MethodChannel('omniterm/biometrics').invokeMethod<void>('cancel');
      expect(await attempt, isTrue, reason: 'Only successful system authentication may pass');
    });
  }
}
