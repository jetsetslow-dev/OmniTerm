import 'package:intl/intl.dart';

/// Temperature unit handling, ported from `ui/MeasurementUnits.kt`.
enum MeasurementSystem {
  metric('metric'),
  imperial('imperial');

  const MeasurementSystem(this.settingValue);

  /// The value persisted in `app_settings`; must not change.
  final String settingValue;

  static MeasurementSystem fromSetting(String? value) {
    for (final system in MeasurementSystem.values) {
      if (system.settingValue == value) return system;
    }
    return MeasurementSystem.metric;
  }
}

double celsiusToDisplay(double celsius, MeasurementSystem system) =>
    system == MeasurementSystem.imperial ? celsius * 9 / 5 + 32 : celsius;

double displayTemperatureToCelsius(double value, MeasurementSystem system) =>
    system == MeasurementSystem.imperial ? (value - 32) * 5 / 9 : value;

String temperatureUnit(MeasurementSystem system) =>
    system == MeasurementSystem.imperial ? '°F' : '°C';

/// Formats a temperature for display in the user's locale.
///
/// The Kotlin used `"%.${decimals}f%s".format(Locale.getDefault(), …)` — deliberately the *default*
/// locale, unlike `humanBytes`, which forces `Locale.US`. So the decimal separator here follows the
/// device (21,5°C in German). That is reproduced by formatting the digits with Dart's
/// `toStringAsFixed` — which rounds half away from zero, as Java's `%f` does — and then swapping in
/// the locale's decimal separator, rather than using [NumberFormat] directly, whose default
/// half-even rounding would disagree at exact .5 boundaries.
String formatTemperature(
  double celsius,
  MeasurementSystem system, {
  int decimals = 0,
  String? locale,
}) {
  final value = celsiusToDisplay(celsius, system);
  var text = value.toStringAsFixed(decimals);
  if (decimals > 0) {
    final separator = NumberFormat.decimalPattern(locale).symbols.DECIMAL_SEP;
    text = text.replaceFirst('.', separator);
  }
  return '$text${temperatureUnit(system)}';
}
