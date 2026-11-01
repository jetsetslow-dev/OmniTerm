import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/ui/theme/text_scaling.dart';

void main() {
  test('Kotlin text presets survive decoding and saving', () {
    for (final (name, percent) in [('small', 80), ('normal', 92), ('large', 110)]) {
      final prefs = AppPreferences.decode({'text_scale': name});
      expect(prefs.textScalePercent, percent);
      expect(prefs.encode()['text_scale'], name);
    }
    expect(AppPreferences.decode({}).textScalePercent, 92);
    expect(AppPreferences.decode({'text_scale': '150'}).textScalePercent, 150);
  });

  test('app sizing preserves the phone accessibility scale', () {
    const scaler = OmniTextScaler(TextScaler.linear(1.5), .92);
    expect(scaler.scale(16), closeTo(22.08, .001));
    expect(scaler.scale(32), closeTo(44.16, .001));
  });

  test('the platform nonlinear curve is not flattened to a single multiplier', () {
    const scaler = OmniTextScaler(_PlatformCurve(), .8);
    expect(scaler.scale(12), closeTo(19.2, .001));
    expect(scaler.scale(32), closeTo(38.4, .001));
  });
}

class _PlatformCurve extends TextScaler {
  const _PlatformCurve();

  @override
  double scale(double fontSize) => fontSize * (fontSize <= 16 ? 2 : 1.5);

  @override
  double get textScaleFactor => 2;
}
