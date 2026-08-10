import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/widgets/metric_line_chart.dart';

/// The chart's height against the user's text size.
///
/// The axis labels sit beside a fixed-height plot. At 200% text three stacked labels no longer fit
/// 56px, and the column overflowed by 118px on every screen that draws a chart — found by adding a
/// 200% pass to the device surface sweep.
void main() {
  Future<void> pumpChart(WidgetTester tester, double scale) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const Scaffold(
            // Column(min) so the chart reports its *natural* height. Given the whole body it would
            // simply fill the viewport, and every size assertion would read the same number.
            body: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MetricLineChart(points: [10, 40, 30], timestamps: []),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('at the default text size the chart is unchanged', (tester) async {
    await pumpChart(tester, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('at 200% text the axis labels still fit', (tester) async {
    // The regression this exists for. An overflow here is a clipped axis on Fleet and Monitor.
    await pumpChart(tester, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the chart grows with the text rather than clipping it', (tester) async {
    await pumpChart(tester, 1);
    final atDefault = tester.getSize(find.byType(MetricLineChart)).height;
    await pumpChart(tester, 2);
    final atLarge = tester.getSize(find.byType(MetricLineChart)).height;

    expect(atLarge, greaterThan(atDefault));
  });

  testWidgets('at the largest supported text size the chart stays a chart', (tester) async {
    // 200% is the ceiling the Settings screen offers, so it is the size worth holding a bound
    // against. Past it the labels keep growing and the plot does not — correct for legibility, and
    // outside what the app lets anyone select.
    await pumpChart(tester, 2);
    final atMax = tester.getSize(find.byType(MetricLineChart)).height;

    expect(atMax, lessThan(300), reason: 'a chart taller than this owns the screen');
    expect(tester.takeException(), isNull);
  });
}
