import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:omniterm/platform/biometric_auth.dart';

/// Records what the wrapper asks the platform for, and answers with whatever the test set up.
class _FakeLocalAuth extends LocalAuthentication {
  _FakeLocalAuth({
    this.deviceSupported = true,
    this.hasHardware = true,
    this.enrolled = const [BiometricType.fingerprint],
    this.result = true,
    this.throwOnAuthenticate = false,
  });

  final bool deviceSupported;
  final bool hasHardware;
  final List<BiometricType> enrolled;
  final bool result;
  final bool throwOnAuthenticate;

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
    return result;
  }
}

void main() {
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

    test('a refusal is false, never an exception', () async {
      // A lock screen that crashes on a cancelled prompt is worse than one that asks for the PIN.
      final auth = _FakeLocalAuth(throwOnAuthenticate: true);
      expect(await BiometricAuth(auth: auth).prompt('Unlock OmniTerm'), isFalse);
    });
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
