import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../domain/biometric_failure.dart';

/// The platform biometric / device-credential prompt.
///
/// Wrapped rather than used directly so the lock controller depends on a plain function and can be
/// tested without a fingerprint reader. Cancellation returns false; unavailable hardware, lockout
/// and integration errors become actionable failures for the controller to show beside PIN fallback.
class BiometricAuth {
  BiometricAuth({LocalAuthentication? auth, MethodChannel? androidChannel, bool? useAndroid})
    : _auth = auth ?? LocalAuthentication(),
      _androidChannel = androidChannel ?? const MethodChannel('omniterm/biometrics'),
      _useAndroid =
          useAndroid ??
          (auth == null && !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final LocalAuthentication _auth;
  final MethodChannel _androidChannel;
  final bool _useAndroid;

  /// True when the device has a **biometric enrolled** to check against.
  ///
  /// Checked before offering the option: enabling "unlock with biometrics" on a device with none
  /// enrolled would leave the user staring at a button that can never succeed.
  ///
  /// Android uses Kotlin's `canAuthenticate(BIOMETRIC_STRONG)` policy. On other platforms, query
  /// enrolled biometrics: a hardware capability check alone also accepts an empty enrolment list.
  Future<bool> isAvailable() async {
    try {
      if (_useAndroid) return await _androidChannel.invokeMethod<bool>('isAvailable') ?? false;
      return await _auth.isDeviceSupported() && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> prompt(String reason) async {
    try {
      if (_useAndroid) {
        return await _androidChannel.invokeMethod<bool>('authenticate', {'reason': reason}) ??
            false;
      }
      return await _auth.authenticate(
        localizedReason: reason,
        // Non-Android platforms use their biometric-only prompt. Android's native bridge above
        // additionally enforces Kotlin's BIOMETRIC_STRONG and per-use Keystore challenge, which
        // local_auth does not expose. The fallback remains the separate OmniTerm PIN.
        biometricOnly: true,
        // The system can interrupt the prompt when the app is backgrounded; retrying on return is
        // better than reporting a failure the user did not cause.
        persistAcrossBackgrounding: true,
      );
    } on PlatformException catch (error) {
      throw BiometricFailure(
        error.message ??
            'Could not open biometric authentication. Retry or enter your OmniTerm PIN.',
      );
    } on LocalAuthException catch (error) {
      switch (error.code) {
        case LocalAuthExceptionCode.userCanceled:
        case LocalAuthExceptionCode.systemCanceled:
        case LocalAuthExceptionCode.userRequestedFallback:
          return false;
        case LocalAuthExceptionCode.noCredentialsSet:
        case LocalAuthExceptionCode.noBiometricsEnrolled:
          throw const BiometricFailure(
            'Set up biometrics in your phone settings, or enter your OmniTerm PIN.',
          );
        case LocalAuthExceptionCode.temporaryLockout:
        case LocalAuthExceptionCode.biometricLockout:
          throw const BiometricFailure(
            'Biometrics are locked. Unlock your phone and retry, or enter your OmniTerm PIN.',
          );
        case LocalAuthExceptionCode.noBiometricHardware:
        case LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
          throw const BiometricFailure(
            'The biometric sensor is unavailable. Retry or enter your OmniTerm PIN.',
          );
        default:
          throw const BiometricFailure(
            'Could not open biometric authentication. Retry or enter your OmniTerm PIN.',
          );
      }
    } catch (_) {
      throw const BiometricFailure(
        'Could not open biometric authentication. Retry or enter your OmniTerm PIN.',
      );
    }
  }
}
