import 'package:flutter/material.dart';

import '../../domain/monitor_history.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// A small time series with axis labels, ported from `MetricLineChart` in `ui/FleetScreen.kt`.
///
/// The point of it is the shape, not the number: 90% CPU that has been 90% all morning is a busy
/// host, and 90% that was 5% a minute ago is something that just started. The current figure beside
/// it cannot tell those apart, which is why the Kotlin puts a chart under every headline reading.
///
/// Fixed axis at 0..[maxY] rather than one scaled to the data. An auto-scaled axis redraws a host
/// idling between 1% and 3% as a dramatic mountain range, and someone glancing at it reads a
/// problem that is not there.
class MetricLineChart extends StatelessWidget {
  const MetricLineChart({
    super.key,
    required this.points,
    this.timestamps = const [],
    this.color = OmniColors.cyan,
    this.label = 'CPU',
    this.unit = '%',
    this.maxY = 100,
    this.height = 56,
  });

  /// Oldest first. One sample draws no line — a single point is not a trend.
  final List<double> points;

  /// Milliseconds since the epoch, parallel to [points], for the two end labels. Empty is allowed:
  /// the chart then says "—" rather than inventing a time range.
  final List<int> timestamps;

  final Color color;
  final String label;
  final String unit;
  final double maxY;
  final double height;

  @override
  Widget build(BuildContext context) {
    final axisColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final axisStyle = TextStyle(fontSize: 10, fontFamily: OmniFonts.mono, color: axisColor);
    final labels = chartEndpointLabels(timestamps);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // The sample count is not decoration: it is how "flat because nothing changed" is told
            // apart from "flat because we have two readings".
            Text(
              '$label · ${points.length} ${points.length == 1 ? "sample" : "samples"}',
              style: axisStyle,
            ),
            Text(
              points.isEmpty ? '—' : '${points.last.round()}$unit',
              key: ValueKey('chart.$label.latest'),
              style: axisStyle.copyWith(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: height,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${maxY.round()}', style: axisStyle),
                      Text('${(maxY / 2).round()}', style: axisStyle),
                      Text('0', style: axisStyle),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: CustomPaint(
                  painter: _ChartPainter(points: points, color: color, maxY: maxY),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(labels.$1, style: axisStyle),
              Text(labels.$2, style: axisStyle),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  const _ChartPainter({required this.points, required this.color, required this.maxY});

  final List<double> points;
  final Color color;
  final double maxY;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = OmniColors.border
      ..strokeWidth = 1;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    if (points.length < 2) return;

    final path = Path();
    final dx = size.width / (points.length - 1);
    for (var i = 0; i < points.length; i++) {
      // Clamped rather than rescaled: a reading above the axis is pinned to the top, so a chart of
      // percentages cannot be redrawn at a different scale by one bad sample.
      final value = (points[i] / maxY).clamp(0.0, 1.0);
      final offset = Offset(i * dx, size.height - value * size.height);
      i == 0 ? path.moveTo(offset.dx, offset.dy) : path.lineTo(offset.dx, offset.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.color != color || old.maxY != maxY || !_sameSeries(old.points, points);

  static bool _sameSeries(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
