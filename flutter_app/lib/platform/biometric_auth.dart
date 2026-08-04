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

  /// True when the device has an enrolled biometric or device credential to check against.
  ///
  /// Checked before offering the option: enabling "unlock with biometrics" on a device with none
  /// enrolled would leave the user staring at a button that can never succeed.
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> prompt(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // The device PIN/pattern is accepted as well as a fingerprint: refusing it would lock out
        // anyone whose sensor is wet, gloved, or simply worn out, and it is the same secret the
        // device lock screen already trusts.
        biometricOnly: false,
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
