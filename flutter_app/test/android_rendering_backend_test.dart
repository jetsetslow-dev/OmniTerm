import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Release rendering configuration that must stay identical to the APK tested on physical phones.
void main() {
  test('Android uses the compatibility renderer instead of a device-specific black frame', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final impellerSetting = RegExp(
      r'<meta-data\s+android:name="io\.flutter\.embedding\.android\.EnableImpeller"\s+'
      r'android:value="([^"]+)"\s*/>',
    ).firstMatch(manifest);

    expect(impellerSetting, isNotNull, reason: 'the release renderer must be chosen explicitly');
    expect(
      impellerSetting!.group(1),
      'false',
      reason:
          'Impeller produced a black screen on a physical phone while the emulator stayed green',
    );
  });
}
