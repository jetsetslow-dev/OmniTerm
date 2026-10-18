/// Serialises JSON the way Android's `org.json` does, so a file written here is byte-for-byte the
/// file the Kotlin app writes for the same data.
///
/// The Kotlin app builds every backup with `JSONObject.toString()`. That output differs from
/// `jsonEncode` in three visible ways, all reproduced here:
///
/// * `/` is escaped as `\/` (most visible in the base64 salt, IV and ciphertext of an envelope);
/// * a double with an integral value is written without a fraction (`90`, not `90.0`);
/// * `JSONObject.put(name, null)` removes the name, so a null map value is omitted entirely.
///
/// Maps keep insertion order, as `JSONObject`'s `LinkedHashMap` does.
library;

String encodeAndroidJson(Object? value) {
  final out = StringBuffer();
  _write(out, value);
  return out.toString();
}

void _write(StringBuffer out, Object? value) {
  switch (value) {
    case null:
      out.write('null');
    case final bool flag:
      out.write(flag ? 'true' : 'false');
    case final int number:
      out.write(number);
    case final double number:
      out.write(_number(number));
    case final String text:
      _string(out, text);
    case final Map<dynamic, dynamic> map:
      out.write('{');
      var first = true;
      for (final entry in map.entries) {
        if (entry.value == null) continue;
        if (!first) out.write(',');
        first = false;
        _string(out, entry.key as String);
        out.write(':');
        _write(out, entry.value);
      }
      out.write('}');
    case final Iterable<dynamic> list:
      out.write('[');
      var first = true;
      for (final entry in list) {
        if (!first) out.write(',');
        first = false;
        _write(out, entry);
      }
      out.write(']');
    default:
      throw ArgumentError.value(value, 'value', 'Not a JSON value');
  }
}

/// `JSONObject.numberToString`: an integral double prints as a long.
String _number(double value) {
  if (!value.isFinite) throw ArgumentError.value(value, 'value', 'JSON forbids NaN and infinity');
  if (value == 0 && value.isNegative) return '-0';
  if (value == value.truncateToDouble() && value.abs() < 9.2e18) return '${value.toInt()}';
  final magnitude = value.abs();
  if (magnitude >= 1e-3 && magnitude < 1e7) return '$value';
  // Java's Double.toString switches to computerized scientific notation outside that range.
  final [mantissa, exponent] = value.toStringAsExponential().split('e');
  return '${mantissa.contains('.') ? mantissa : '$mantissa.0'}E${exponent.replaceFirst('+', '')}';
}

/// `JSONStringer.string`: quote, backslash and solidus are backslash-escaped, the five short
/// control escapes are used, and any other control character becomes a lowercase `\u00xx`.
void _string(StringBuffer out, String value) {
  out.write('"');
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x2F:
        out.write(r'\/');
      case 0x09:
        out.write(r'\t');
      case 0x08:
        out.write(r'\b');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x0C:
        out.write(r'\f');
      default:
        if (unit <= 0x1F) {
          out.write(r'\u');
          out.write(unit.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.write('"');
}
