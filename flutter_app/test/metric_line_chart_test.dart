import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/widgets/metric_line_chart.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget chart) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SizedBox(width: 300, child: chart))),
  );

  testWidgets('the latest reading is stated, not only drawn', (tester) async {
    // A line without its current value makes the reader estimate a number off a 56px canvas.
    await pump(tester, const MetricLineChart(points: [10, 20, 35.6], label: 'CPU'));

    expect(find.text('36%'), findsOneWidget);
    expect(find.text('CPU · 3 samples'), findsOneWidget);
  });

  testWidgets('an empty series says so rather than drawing a flat line at zero', (tester) async {
    // A line along the bottom is a claim that the host was idle for the whole window.
    await pump(tester, const MetricLineChart(points: [], label: 'CPU'));

    expect(find.text('—'), findsWidgets);
    expect(find.text('CPU · 0 samples'), findsOneWidget);
  });

  testWidgets('one sample is one sample', (tester) async {
    // The Kotlin renders "1 samples". Small, but it is the first thing shown after connecting to a
    // host, which is exactly when a user is deciding whether the app is careful.
    await pump(tester, const MetricLineChart(points: [7], label: 'CPU'));
    expect(find.text('CPU · 1 sample'), findsOneWidget);
  });

  testWidgets('the sample count distinguishes a flat host from a new one', (tester) async {
    // Two identical readings and two hundred identical readings draw the same line and mean very
    // different things.
    await pump(tester, const MetricLineChart(points: [50, 50], label: 'RAM'));
    expect(find.text('RAM · 2 samples'), findsOneWidget);
  });

  testWidgets('the axis is fixed at 0..100, whatever the data does', (tester) async {
    // An axis scaled to the data redraws a host idling between 1% and 3% as a mountain range.
    await pump(tester, const MetricLineChart(points: [1, 3, 2], label: 'CPU'));

    expect(find.text('100'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('a custom axis maximum is labelled as such', (tester) async {
    await pump(tester, const MetricLineChart(points: [10], label: 'Temp', unit: '°C', maxY: 120));

    expect(find.text('120'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('10°C'), findsOneWidget);
  });

  testWidgets('timestamps become the two end labels', (tester) async {
    final start = DateTime(2026, 8, 5, 14, 30, 15);
    await pump(
      tester,
      MetricLineChart(
        points: const [1, 2],
        timestamps: [
          start.millisecondsSinceEpoch,
          start.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
        ],
      ),
    );

    // Under an hour apart, so seconds are shown — the same rule `chartEndpointLabels` already tests.
    expect(find.text('14:30:15'), findsOneWidget);
    expect(find.text('14:30:45'), findsOneWidget);
  });

  testWidgets('a series with no timestamps does not invent a time range', (tester) async {
    await pump(tester, const MetricLineChart(points: [1, 2, 3]));
    expect(find.text('—'), findsNWidgets(2));
  });

  testWidgets('one sample renders without drawing a line', (tester) async {
    // A single point is not a trend, and joining it to the axis would draw a fall that never
    // happened. It must still not throw.
    await pump(tester, const MetricLineChart(points: [42]));
    expect(tester.takeException(), isNull);
    expect(find.text('42%'), findsOneWidget);
  });
}
