import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/license_controller.dart';

void main() {
  group('LicenseState', () {
    test('copyWith updates specified fields', () {
      const state = LicenseState();
      final updated = state.copyWith(
        enabled: true,
        loading: true,
        unlocked: false,
        productPrice: '\$4.99',
      );

      expect(updated.enabled, isTrue);
      expect(updated.loading, isTrue);
      expect(updated.unlocked, isFalse);
      expect(updated.adsRemoved, isTrue); // default unchanged
      expect(updated.productPrice, equals('\$4.99'));
    });

    test('equality and hashCode match values', () {
      const s1 = LicenseState(enabled: true, unlocked: false, productPrice: '\$1.99');
      const s2 = LicenseState(enabled: true, unlocked: false, productPrice: '\$1.99');
      const s3 = LicenseState(enabled: true, unlocked: true, productPrice: '\$1.99');

      expect(s1, equals(s2));
      expect(s1.hashCode, equals(s2.hashCode));
      expect(s1, isNot(equals(s3)));
    });
  });

  group('DisabledLicenseController', () {
    test('returns default unlocked state for open source / disabled build', () {
      final controller = DisabledLicenseController();
      expect(controller.state.value.enabled, isFalse);
      expect(controller.state.value.unlocked, isTrue);
      expect(controller.state.value.adsRemoved, isTrue);

      controller.start();
      controller.refresh();
      controller.onResume();
      expect(controller.state.value.unlocked, isTrue);

      controller.dispose();
    });
  });
}
