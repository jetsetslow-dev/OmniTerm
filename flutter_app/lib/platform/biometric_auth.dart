import 'package:local_auth/local_auth.dart';

/// The platform biometric / device-credential prompt.
///
/// Wrapped rather than used directly so the lock controller depends on a plain function and can be
/// tested without a fingerprint reader (Convention 4). [prompt] returns false — never throws — for
/// every "no" the platform can give, because a lock screen that crashes on a cancelled prompt is
/// worse than one that simply asks for the PIN.
class BiometricAuth {
  BiometricAuth({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// True when the device has a **biometric enrolled** to check against.
  ///
  /// Checked before offering the option: enabling "unlock with biometrics" on a device with none
  /// enrolled would leave the user staring at a button that can never succeed.
  ///
  /// `canCheckBiometrics` is not that check. It resolves to `deviceSupportsBiometrics()` — whether
  /// the hardware exists — and is true on a phone with a fingerprint reader and nothing enrolled on
  /// it. `getAvailableBiometrics()` resolves to `getEnrolledBiometrics()`, which is what Kotlin's
  /// `canAuthenticate(BIOMETRIC_STRONG) == BIOMETRIC_SUCCESS` means
  /// (`data/BiometricCryptoGate.kt:44`).
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported() && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> prompt(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // A biometric, not the device credential. Kotlin allows exactly one authenticator —
        // `setAllowedAuthenticators(BIOMETRIC_STRONG)` at `data/BiometricCryptoGate.kt:91`, with no
        // `DEVICE_CREDENTIAL` — and the reason is the threat this gate exists for. The lock and the
        // sudo re-prompt both defend against someone *holding the unlocked phone*
        // (`app_lock_controller.dart:268`); accepting the device PIN would let that person through
        // with the very secret that unlocked it, which is not a re-identification at all.
        //
        // Nobody is locked out by this: a worn or wet sensor falls back to the app's own PIN, which
        // is a different secret from the device's and is what the lock screen offers underneath.
        biometricOnly: true,
        // The system can interrupt the prompt when the app is backgrounded; retrying on return is
        // better than reporting a failure the user did not cause.
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      // "No hardware", "not enrolled", "locked out" and a plain cancel all mean the same thing
      // here: fall back to the PIN. Caught broadly because the plugin raises its own
      // `LocalAuthException` as well as `PlatformException`, and neither should reach the UI.
      return false;
    }
  }
}
