import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/license_controller.dart';
import 'package:omniterm/ui/widgets/ad_banner.dart';

class MockTestLicenseController implements LicenseController {
  MockTestLicenseController(this.initialState);

  final LicenseState initialState;
  late final ValueNotifier<LicenseState> _notifier = ValueNotifier(initialState);

  bool purchaseLaunched = false;

  @override
  ValueListenable<LicenseState> get state => _notifier;

  @override
  void start() {}

  @override
  void refresh() {}

  @override
  void onResume() {}

  @override
  Future<void> launchPurchase() async {}

  @override
  Future<void> launchAdRemovalPurchase() async {
    purchaseLaunched = true;
  }

  @override
  void dispose() {
    _notifier.dispose();
  }
}

void main() {
  group('AdBanner Widget', () {
    testWidgets('renders SizedBox.shrink when licenseController is null', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AdBanner())));

      expect(find.byKey(const ValueKey('adBanner.container')), findsNothing);
    });

    testWidgets('renders SizedBox.shrink when ads operate in disabled/unlocked mode', (
      tester,
    ) async {
      final controller = DisabledLicenseController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdBanner(licenseController: controller)),
        ),
      );

      expect(find.byKey(const ValueKey('adBanner.container')), findsNothing);
      controller.dispose();
    });

    testWidgets('renders AdBanner when enabled and ads non-removed', (tester) async {
      final controller = MockTestLicenseController(
        const LicenseState(
          enabled: true,
          loading: false,
          unlocked: false,
          adsRemoved: false,
          adRemovalPrice: '\$0.99',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdBanner(licenseController: controller)),
        ),
      );

      expect(find.byKey(const ValueKey('adBanner.container')), findsOneWidget);
      expect(find.text('\$0.99'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('adBanner.removeAds')));
      await tester.pump();

      expect(controller.purchaseLaunched, isTrue);
      controller.dispose();
    });
  });
}
