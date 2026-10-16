import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:omniterm/domain/biometric_failure.dart';
import 'package:omniterm/platform/biometric_auth.dart';

/// Records what the wrapper asks the platform for, and answers with whatever the test set up.
class _FakeLocalAuth extends LocalAuthentication {
  _FakeLocalAuth({
    this.deviceSupported = true,
    this.hasHardware = true,
    this.enrolled = const [BiometricType.fingerprint],
    this.result = true,
    this.throwOnAuthenticate = false,
    this.error,
  });

  final bool deviceSupported;
  final bool hasHardware;
  final List<BiometricType> enrolled;
  final bool result;
  final bool throwOnAuthenticate;
  final LocalAuthException? error;

  bool? lastBiometricOnly;
  bool? lastPersistAcrossBackgrounding;
  String? lastReason;

  @override
  Future<bool> isDeviceSupported() async => deviceSupported;

  @override
  Future<bool> get canCheckBiometrics async => hasHardware;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => enrolled;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    // `AuthMessages` is not exported by `package:local_auth/local_auth.dart`, and pulling in
    // the platform interface package just to name it would add a dependency for a parameter
    // this fake ignores. Dart allows an override to widen a parameter to a supertype.
    Iterable<Object?> authMessages = const <Object?>[],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    lastReason = localizedReason;
    lastBiometricOnly = biometricOnly;
    lastPersistAcrossBackgrounding = persistAcrossBackgrounding;
    if (throwOnAuthenticate) throw StateError('platform said no');
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Android Kotlin-compatible gate', () {
    const channel = MethodChannel('omniterm/biometrics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('uses the native strong biometric gate for availability and authentication', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final auth = BiometricAuth(useAndroid: true);
      expect(await auth.isAvailable(), isTrue);
      expect(await auth.prompt('Unlock OmniTerm'), isTrue);
      expect(calls.map((call) => call.method), ['isAvailable', 'authenticate']);
      expect(calls.last.arguments, {'reason': 'Unlock OmniTerm'});
    });

    test('preserves a native error for PIN fallback and treats cancel as false', () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'unavailable',
          message: 'Sensor unavailable. Enter your OmniTerm PIN.',
        );
      });
      final auth = BiometricAuth(useAndroid: true);
      await expectLater(auth.prompt('Unlock OmniTerm'), throwsA(isA<BiometricFailure>()));
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      expect(await auth.prompt('Unlock OmniTerm'), isFalse);
    });
  });

  group('the prompt', () {
    test('asks for a biometric, not the device credential', () async {
      // Kotlin allows one authenticator and one only: `setAllowedAuthenticators(BIOMETRIC_STRONG)`
      // at `data/BiometricCryptoGate.kt:91`, with no `DEVICE_CREDENTIAL`. Accepting the device PIN
      // here would let whoever unlocked the phone straight through the lock that exists to stop
      // them, using the same secret.
      final auth = _FakeLocalAuth();

      expect(await BiometricAuth(auth: auth).prompt('Unlock OmniTerm'), isTrue);

      expect(auth.lastBiometricOnly, isTrue);
      expect(auth.lastReason, 'Unlock OmniTerm');
    });

    test(
      'retries across backgrounding rather than reporting a failure the user did not cause',
      () async {
        final auth = _FakeLocalAuth();
        await BiometricAuth(auth: auth).prompt('Unlock OmniTerm');
        expect(auth.lastPersistAcrossBackgrounding, isTrue);
      },
    );

    test('a cancelled prompt is a plain false', () async {
      // The platform reports a user cancel as a false return rather than a throw, and it has to
      // reach the caller unchanged — the lock screen decides what to do about it, not this wrapper.
      final auth = _FakeLocalAuth(result: false);
      expect(await BiometricAuth(auth: auth).prompt('Unlock OmniTerm'), isFalse);
    });

    test('an integration failure explains the PIN fallback', () async {
      final auth = _FakeLocalAuth(throwOnAuthenticate: true);
      await expectLater(
        BiometricAuth(auth: auth).prompt('Unlock OmniTerm'),
        throwsA(
          isA<BiometricFailure>().having((e) => e.message, 'message', contains('OmniTerm PIN')),
        ),
      );
    });

    for (final code in [
      LocalAuthExceptionCode.userCanceled,
      LocalAuthExceptionCode.systemCanceled,
      LocalAuthExceptionCode.userRequestedFallback,
    ]) {
      test('$code is cancellation, not an error', () async {
        final auth = _FakeLocalAuth(error: LocalAuthException(code: code));
        expect(await BiometricAuth(auth: auth).prompt('Unlock OmniTerm'), isFalse);
      });
    }

    for (final (code, message) in [
      (LocalAuthExceptionCode.uiUnavailable, 'Could not open'),
      (LocalAuthExceptionCode.noBiometricsEnrolled, 'phone settings'),
      (LocalAuthExceptionCode.temporaryLockout, 'locked'),
      (LocalAuthExceptionCode.noBiometricHardware, 'sensor is unavailable'),
    ]) {
      test('$code gives an actionable failure', () async {
        final auth = _FakeLocalAuth(error: LocalAuthException(code: code));
        await expectLater(
          BiometricAuth(auth: auth).prompt('Unlock OmniTerm'),
          throwsA(isA<BiometricFailure>().having((e) => e.message, 'message', contains(message))),
        );
      });
    }
  });

  group('availability', () {
    test('hardware with nothing enrolled is not available', () async {
      // The trap this replaces: `canCheckBiometrics` resolves to `deviceSupportsBiometrics()`, so a
      // phone with a fingerprint reader and no finger registered answered yes — and the option it
      // gated could never succeed. Kotlin's `canAuthenticate(BIOMETRIC_STRONG)` means *enrolled*.
      final auth = _FakeLocalAuth(hasHardware: true, enrolled: const []);
      expect(await BiometricAuth(auth: auth).isAvailable(), isFalse);
    });

    test('an enrolled biometric is available', () async {
      final auth = _FakeLocalAuth(enrolled: const [BiometricType.fingerprint]);
      expect(await BiometricAuth(auth: auth).isAvailable(), isTrue);
    });

    test('a device with no secure lock at all is not available', () async {
      final auth = _FakeLocalAuth(deviceSupported: false);
      expect(await BiometricAuth(auth: auth).isAvailable(), isFalse);
    });
  });
}
