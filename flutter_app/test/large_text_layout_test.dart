import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/screens/tools/tools_hub_screen.dart';
import 'package:omniterm/ui/widgets/omni_components.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:provider/provider.dart';

/// Layouts at the largest text size the Settings screen offers.
///
/// Found by adding a 200% pass to the device surface sweep: seven surfaces clipped their content,
/// and a user who needs large text is exactly the user least able to work around a clipped control.
///
/// **Overflow itself is asserted on the device, not here.** A widget test has to invent a viewport,
/// and an invented one either cannot fail (the 800x600 default is wider than a phone, so the grid
/// fits at any scale) or reproduces constraints the real screen never has. What this file pins is
/// the *property* the fix relies on — tiles that grow with the text — with the sweep as the
/// authority on whether anything still clips.
void main() {
  Future<void> pumpAt(WidgetTester tester, Widget child, double scale) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: ChangeNotifierProvider<NavigationController>(
            create: (_) => NavigationController(),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('the tools hub grid', () {
    testWidgets('lays out at the default text size', (tester) async {
      await pumpAt(tester, const ToolsHubScreen(), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the tiles grow rather than the text shrinking', (tester) async {
      await pumpAt(tester, const ToolsHubScreen(), 1);
      final small = tester.getSize(find.byKey(const ValueKey('tools.network'))).height;
      await pumpAt(tester, const ToolsHubScreen(), 2);
      final large = tester.getSize(find.byKey(const ValueKey('tools.network'))).height;

      expect(large, greaterThan(small));
    });
  });

  group('scaledBarHeight', () {
    // Tab strips and chip rows are laid out at a constant height so they do not jitter. That
    // constant is a clipping bug at large text: Monitor's 40px tab bar lost 44px at 200%, which is
    // the whole strip. Pure, so the rule is pinned without inventing a viewport — the device sweep
    // remains the authority on whether anything still clips.
    Future<double> heightAt(WidgetTester tester, double scale, double base) async {
      late double result;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Builder(
              builder: (context) {
                result = scaledBarHeight(context, base);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      return result;
    }

    testWidgets('the default text size leaves the bar alone', (tester) async {
      expect(await heightAt(tester, 1, 40), 40);
    });

    testWidgets('the bar grows with the text', (tester) async {
      expect(await heightAt(tester, 2, 40), 80);
      expect(await heightAt(tester, 1.5, 44), 66);
    });

    testWidgets('growth is capped so the bar cannot own the screen', (tester) async {
      expect(await heightAt(tester, 4, 40), 80);
    });

    testWidgets('a text size below the default does not shrink the bar', (tester) async {
      // 80% is offered in Settings, and a chip row shorter than its touch target is its own defect.
      expect(await heightAt(tester, 0.8, 40), 40);
    });
  });
}
