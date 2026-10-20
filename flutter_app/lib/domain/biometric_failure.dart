/// An actionable biometric failure. Cancellation is a normal false result instead.
class BiometricFailure implements Exception {
  const BiometricFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
