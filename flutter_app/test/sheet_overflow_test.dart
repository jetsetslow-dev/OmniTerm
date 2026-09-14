import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/license_controller.dart';
import 'package:omniterm/ui/widgets/license_gate.dart';

/// A modal bottom sheet clips too, and for a reason that is easy to miss.
///
/// Without `isScrollControlled: true`, `showModalBottomSheet` caps the sheet at **half** the
/// available height. On a small phone in landscape that is ~180 logical pixels, and at 200% text an
/// icon, a heading, a paragraph and two buttons do not come close to fitting. The overflow is the
/// same failure as parity defects 112-115 in a different container: what falls off the bottom of a
/// premium gate is the button the sheet exists to offer.
void main() {
  Future<List<String>> overflowsWhile(
    WidgetTester tester,
    Future<void> Function(BuildContext context) show, {
    Size size = const Size(640, 360),
    double textScale = 2,
  }) async {
    final overflows = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) overflows.add(details.toString());
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Builder(
              builder: (context) =>
                  TextButton(onPressed: () => show(context), child: const Text('open')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return overflows;
  }

  testWidgets('the premium gate fits a small phone in landscape at 200% text', (tester) async {
    final controller = DisabledLicenseController();
    addTearDown(controller.dispose);

    final overflows = await overflowsWhile(
      tester,
      (context) => showPremiumGate(
        context,
        controller: controller,
        title: 'Quick Connect Requires Premium',
        // The length a real message reaches — a short one hides the defect, which is how the
        // equivalent test for defect 113 passed at the wrong geometry before being tightened.
        message:
            'Connecting without saving a host is a premium feature. Unlock OmniTerm to use it, or '
            'add the host to your list and connect from there.',
      ),
    );

    expect(find.byKey(const ValueKey('license.gate')), findsOneWidget, reason: 'the sheet is open');
    expect(overflows, isEmpty, reason: 'the premium gate overflowed: ${overflows.join('; ')}');
  });
}
