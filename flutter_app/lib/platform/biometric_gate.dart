import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// A gateway for biometric authentication, ported from `BiometricCryptoGate.kt`.
class BiometricGate {
  BiometricGate({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Checks if strong biometric authentication is available on the device.
  Future<bool> canAuthenticate() async {
    try {
      final isAvailable = await _auth.canCheckBiometrics;
      final isDeviceSupported = await _auth.isDeviceSupported();
      return isAvailable && isDeviceSupported;
    } on PlatformException {
      return false;
    }
  }

  /// Attempts to authenticate the user using strong biometrics.
  ///
  /// Returns `true` if authentication succeeded, `false` if the user cancelled
  /// or failed, and throws an exception on system errors.
  Future<bool> authenticate({required String title, String? subtitle}) async {
    try {
      return await _auth.authenticate(
        localizedReason: subtitle ?? title,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } on PlatformException catch (e) {
      if (e.code == 'NotAvailable' || e.code == 'NotEnrolled' || e.code == 'PasscodeNotSet') {
        return false;
      }
      if (e.code == 'LockedOut' || e.code == 'PermanentlyLockedOut') {
        return false;
      }
      return false;
    }
  }
}
