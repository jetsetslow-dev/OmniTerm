/// Validators for typed numeric input, ported from `ui/InputValidation.kt`.
///
/// Every one returns null when the text is usable, or a short reason to show on the field. They
/// exist because the screens used to parse with `text.toIntOrNull() ?: default`: an empty or
/// malformed entry silently became a default, so a saved record held a value the user never typed
/// (a port they never chose, an alert threshold that never fires). Refusing to save is always
/// better than inventing one.
///
/// Callers should both disable the confirm action while an error is present and surface the
/// message, so the reason is visible rather than the button being mysteriously dead.
library;

/// TCP/UDP port. Rejects 0, which is "any port" to the kernel and never what a user means here.
String? portError(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return 'Required';
  final value = int.tryParse(trimmed);
  if (value == null) return 'Must be a whole number';
  return (value < 1 || value > 65535) ? 'Must be 1-65535' : null;
}

/// A count that must be at least [min] (retries, replicas, and similar).
String? countError(String input, {int min = 1, int max = 9999}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return 'Required';
  final value = int.tryParse(trimmed);
  if (value == null) return 'Must be a whole number';
  return (value < min || value > max) ? 'Must be $min-$max' : null;
}

/// A 0-100 percentage, used for health-score thresholds.
String? percentError(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return 'Required';
  final value = double.tryParse(trimmed);
  if (value == null) return 'Must be a number';
  // Kotlin guards `isFinite` explicitly because toFloatOrNull accepts "Infinity"/"NaN"; Dart's
  // double.tryParse does the same, so the guard is equally necessary here.
  if (!value.isFinite) return 'Must be a number';
  if (value < 0) return 'Must be 0 or more';
  if (value > 100) return 'Must be 100 or less';
  return null;
}

/// A MAC address in colon or hyphen separated hex, as Wake-on-LAN requires.
String? macAddressError(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return 'Required';
  final octets = trimmed.replaceAll('-', ':').split(':');
  const invalid = 'Use the form AA:BB:CC:DD:EE:FF';
  if (octets.length != 6) return invalid;
  for (final octet in octets) {
    // Kotlin's toIntOrNull(radix = 16) rejects a leading sign and any non-hex character; Dart's
    // int.tryParse(radix: 16) accepts a leading '+'/'-', so the digits are checked explicitly.
    if (octet.length != 2 || !_isHexPair(octet)) return invalid;
  }
  return null;
}

bool _isHexPair(String s) {
  for (final unit in s.codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isUpper = unit >= 0x41 && unit <= 0x46;
    final isLower = unit >= 0x61 && unit <= 0x66;
    if (!isDigit && !isUpper && !isLower) return false;
  }
  return true;
}
