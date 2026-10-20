import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/app_database.dart' show Server;
import '../../domain/host_display.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// Shared surfaces and controls, ported from `ui/OmniComponents.kt`.
///
/// Every screen builds from these, so the metrics here are the app's visual grammar: get the
/// padding or the accent width wrong once and 15 screens inherit it.

/// Card surface with an optional coloured left accent (the host-colour coding from the prototype).
///
/// The accent also changes the corner radius — 4 instead of 10 — which is what makes an
/// accented card read as a list row rather than a floating panel.
class OmniCard extends StatelessWidget {
  const OmniCard({
    super.key,
    required this.child,
    this.leftAccent,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.margin,
    this.inset = EdgeInsets.zero,
  });

  final Widget child;
  final Color? leftAccent;

  /// The caller's own padding inside the card, on top of the card's 12dp. Kotlin call sites
  /// usually wrap their content in `Modifier.padding(12.dp)` (some 16dp) inside `OmniCard`, whose
  /// `Column` already pads 12dp, so their content sits 24dp in.
  final EdgeInsets inset;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(leftAccent != null ? 4 : 10);

    // Compose draws the outline over the accent without adding it to content padding.
    Widget card = Container(
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: radius),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Padding(padding: const EdgeInsets.all(12) + inset, child: child),
          if (leftAccent != null)
            Positioned(left: 0, top: 0, bottom: 0, width: 3, child: ColoredBox(color: leftAccent!)),
        ],
      ),
    );

    if (onTap != null || onLongPress != null) {
      card = Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, borderRadius: radius, child: card),
      );
    }
    if (semanticLabel != null) {
      card = Semantics(label: semanticLabel, container: true, child: card);
    }
    return margin == null ? card : Padding(padding: margin!, child: card);
  }
}

/// A single figure with its label — the summary-banner unit.
class OmniStatBox extends StatelessWidget {
  const OmniStatBox({
    super.key,
    required this.value,
    required this.label,
    this.color,
    this.semanticLabel,
  });

  final String value;
  final String label;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel ?? '$label: $value',
      container: true,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color ?? scheme.onSurface,
              fontFamily: OmniFonts.mono,
              fontWeight: FontWeight.w800,
              fontSize: 20,
              height: 24 / 20,
              letterSpacing: 0.5,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 1.1,
              height: 24 / 10,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small uppercase heading above a list section.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  final String title;
  final Widget? trailing;

  /// Kotlin's default; some call sites pass `Modifier.padding(0.dp)`.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
              fontSize: 11,
              letterSpacing: 1.5,
              height: 24 / 11,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// The app's text-field styling: cyan focus, container fill, outline border.
InputDecoration omniInputDecoration(
  BuildContext context, {
  String? hintText,
  String? labelText,

  /// Persistent guidance under the field, for a choice whose consequence is not obvious from its
  /// label — unlike [hintText], which disappears as soon as the field has a value.
  String? helperText,

  /// Why the current contents cannot be used. Shown in place of [helperText] and turns the border
  /// red, so an invalid field says so where the value is rather than somewhere else on the screen.
  String? errorText,
  Widget? prefixIcon,
  Widget? suffixIcon,
}) {
  final scheme = Theme.of(context).colorScheme;
  return InputDecoration(
    hintText: hintText,
    labelText: labelText,
    helperText: helperText,
    errorText: errorText,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: scheme.surfaceContainer,
    isDense: true,
    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: scheme.outline)),
    focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: OmniColors.cyan)),
    labelStyle: const TextStyle(color: OmniColors.cyan),
  );
}

/// Human-readable byte size, ported from `formatBytes` in `ui/OmniComponents.kt`.
///
/// Note this differs from the terminal's `humanBytes`: it starts at KB rather than reporting bare
/// bytes, because a file listing showing "1024 B" next to "1.0 MB" reads badly.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = -1;
  do {
    value /= 1024;
    unitIndex++;
  } while (value >= 1024 && unitIndex < units.length - 1);
  return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
}

/// Kotlin's `formatUptime`: `"2d 3h 4m"`, always ending in minutes.
String formatUptime(int seconds) {
  if (seconds <= 0) return '—';
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return [if (d > 0) '${d}d', if (h > 0 || d > 0) '${h}h', '${m}m'].join(' ');
}

/// A fixed bar height, grown with the user's text size.
///
/// Tab strips, chip rows and toolbars are laid out at a constant height so they do not jitter as
/// their contents change. That constant is a clipping bug at large text: a chip whose label doubles
/// needs roughly double the height, and the row simply overflows — Monitor's 40px tab bar lost 44px
/// at 200%, which is the whole strip.
///
/// Capped at 2x for the same reason the chart is: past that the bar starts owning the screen it is
/// supposed to sit above.
double scaledBarHeight(BuildContext context, double base) =>
    base * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);

/// Kotlin's `GaugeBar`: a rounded bar on the border-coloured track that turns amber above 70%
/// and red above 85%, whatever [color] the caller asked for.
///
/// [value] is a percentage, clamped: a remote host can report a CPU figure above 100 (multi-core
/// `top` output does) and an unclamped bar would paint outside its track.
class GaugeBar extends StatelessWidget {
  const GaugeBar({
    super.key,
    required this.value,
    this.color = OmniColors.cyan,
    this.height = 4,
    this.semanticLabel,
  });

  final double value;
  final Color color;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final barColor = value > 85
        ? OmniColors.red
        : value > 70
        ? OmniColors.amber
        : color;
    final bar = Container(
      height: height,
      decoration: BoxDecoration(
        color: OmniColors.border,
        borderRadius: BorderRadius.circular(height),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: (value / 100).clamp(0.0, 1.0),
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(height)),
        ),
      ),
    );
    return semanticLabel == null ? bar : Semantics(label: semanticLabel, child: bar);
  }
}

/// Kotlin's `OmniTag`: a small mono pill with a tinted fill and border.
class OmniTag extends StatelessWidget {
  const OmniTag({super.key, required this.label, this.color = OmniColors.cyan});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontFamily: OmniFonts.mono,
          fontWeight: FontWeight.bold,
          fontSize: 10,
          letterSpacing: 0.8,
          height: 24 / 10,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}

/// Kotlin's `OmniTextSize`.
/// Every component text below sets `height: 24 / fontSize`: in Compose the ambient `bodyLarge`
/// keeps its 24sp line height when a component names only a font size (see [composeBody]).
abstract final class OmniTextSize {
  static const section = 11.0;
  static const body = 14.0;
  static const dense = 12.0;
  static const meta = 11.0;
  static const tag = 10.0;
}

/// Kotlin's `StatusDot`: a filled circle, red whenever the host is offline.
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.online,
    this.color = OmniColors.green,
    this.size = 8,
    this.semanticLabel,
  });

  final bool online;
  final Color color;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel ?? (online ? 'Server online' : 'Server offline'),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: online ? color : OmniColors.red, shape: BoxShape.circle),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.strokeFactor,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double strokeFactor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.max(size.width * strokeFactor, 3.0);
    final inset = stroke / 2 + 1;
    final rect = Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}

/// Kotlin's `ScoreRing`: circular health gauge with the score in the display font.
class ScoreRing extends StatelessWidget {
  const ScoreRing({super.key, required this.score, this.size = 44, this.semanticLabel});

  /// Negative means unknown.
  final int score;
  final double size;
  final String? semanticLabel;

  static Color colorFor(int score) => score < 0
      ? OmniColors.textMuted
      : score >= 90
      ? OmniColors.green
      : score >= 70
      ? OmniColors.cyan
      : score >= 50
      ? OmniColors.amber
      : OmniColors.red;

  @override
  Widget build(BuildContext context) {
    final color = colorFor(score);
    return Semantics(
      label:
          semanticLabel ??
          (score < 0
              ? 'Health unavailable. Waiting for verified metrics.'
              : 'Health score: $score out of 100'),
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: (score / 100).clamp(0.0, 1.0),
            color: color,
            track: OmniColors.border,
            strokeFactor: 0.09,
          ),
          child: Center(
            child: Text(
              score < 0 ? '—' : '$score',
              style: TextStyle(
                color: color,
                fontFamily: OmniFonts.display,
                fontWeight: OmniFonts.displayWeight,
                fontSize: size * 0.30,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Kotlin's `RefreshCountdown`: a depleting ring with whole seconds remaining in its centre.
class RefreshCountdown extends StatefulWidget {
  const RefreshCountdown({
    super.key,
    required this.nextAt,
    required this.interval,
    this.size = 30,
    this.color = OmniColors.cyan,
  });

  /// When the next cycle is due; null renders an empty ring (no poller in this build).
  final DateTime? nextAt;
  final Duration interval;
  final double size;
  final Color color;

  @override
  State<RefreshCountdown> createState() => _RefreshCountdownState();
}

class _RefreshCountdownState extends State<RefreshCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Kotlin redraws every 250ms so the ring depletes smoothly rather than in whole-second steps.
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intervalMs = widget.interval.inMilliseconds;
    final next = widget.nextAt;
    final remainingMs = next == null
        ? 0
        : next.difference(DateTime.now()).inMilliseconds.clamp(0, intervalMs);
    final fraction = intervalMs > 0 ? remainingMs / intervalMs : 0.0;
    final secs = (remainingMs + 999) ~/ 1000;
    return Semantics(
      label: 'Refreshing in $secs seconds',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: fraction,
            color: widget.color,
            track: OmniColors.border,
            strokeFactor: 0.10,
          ),
          child: Center(
            child: Text(
              '$secs',
              style: TextStyle(
                color: widget.color,
                fontFamily: OmniFonts.mono,
                fontWeight: FontWeight.bold,
                fontSize: widget.size * 0.34,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Kotlin's `OmniButton`: translucent accent box with mono bold label.
class OmniButton extends StatelessWidget {
  const OmniButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = OmniColors.cyan,
    this.small = false,
    this.expand = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final bool small;

  /// Kotlin callers that pass `Modifier.fillMaxWidth()`.
  final bool expand;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(6);
    Widget box = Container(
      constraints: BoxConstraints(minHeight: small ? 36 : 44),
      padding: EdgeInsets.symmetric(horizontal: small ? 10 : 14, vertical: small ? 5 : 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: radius,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      alignment: expand ? Alignment.center : null,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontFamily: OmniFonts.mono,
          fontWeight: FontWeight.bold,
          fontSize: small ? 10 : 12,
          letterSpacing: 0.6,
          height: 24 / (small ? 10 : 12),
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
    if (!expand) box = IntrinsicWidth(child: Center(widthFactor: 1, child: box));
    return Semantics(
      label: semanticLabel,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: radius, onTap: onPressed, child: box),
      ),
    );
  }
}

/// Kotlin's `MiniMetric`: label + value row over a thin gauge.
class MiniMetric extends StatelessWidget {
  const MiniMetric({
    super.key,
    required this.label,
    required this.value,
    this.color = OmniColors.cyan,
    this.displayValue,
    this.unit = '%',
  });

  final String label;
  final double value;
  final Color color;
  final double? displayValue;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final metricColor = value > 85
        ? OmniColors.red
        : value > 70
        ? OmniColors.amber
        : color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: OmniFonts.mono,
                fontSize: 10,
                height: 24 / 10,
                letterSpacing: 0.5,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            Text(
              '${(displayValue ?? value).toInt()}$unit',
              style: TextStyle(
                color: metricColor,
                fontFamily: OmniFonts.mono,
                fontWeight: FontWeight.bold,
                fontSize: 10,
                height: 24 / 10,
                letterSpacing: 0.5,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        GaugeBar(value: value, color: color, height: 3),
      ],
    );
  }
}

/// Kotlin's `PrimaryTabRow` + `Tab(Text(fontSize = OmniTextSize.Dense))`: equal-width tabs on the
/// surface colour, labels in primary, a 24×3dp rounded indicator under the selected label and a
/// 1dp outline-variant divider.
class OmniTabRow extends StatelessWidget {
  const OmniTabRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.tabKeys,
    this.badges = const {},
    this.disabled = const {},
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// One key per tab, for tests and accessibility tooling.
  final List<Key>? tabKeys;

  /// Widgets shown after a tab's label (Files' transfer count), keyed by tab index.
  final Map<int, Widget> badges;

  /// Tabs that cannot be selected right now, as Kotlin's `Tab(enabled = false)`.
  final Set<int> disabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A Tab's text keeps titleSmall's 20sp line height when Kotlin shrinks it to Dense.
    final style = (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(
      fontSize: OmniTextSize.dense,
      height: 20 / OmniTextSize.dense,
      leadingDistribution: TextLeadingDistribution.even,
      color: scheme.primary,
    );
    return Material(
      color: scheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Equal-height tabs (a label may wrap at large text) without unbounded stretch.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: Semantics(
                      selected: i == selectedIndex,
                      button: true,
                      child: InkWell(
                        key: tabKeys?[i],
                        onTap: disabled.contains(i) ? null : () => onSelected(i),
                        // Kotlin's content-lambda Tab has no 48dp floor: its height is the label
                        // plus the 8dp vertical padding Kotlin gives it (36dp at normal text).
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        labels[i],
                                        textAlign: TextAlign.center,
                                        style: disabled.contains(i)
                                            ? style.copyWith(
                                                color: scheme.onSurface.withValues(alpha: 0.38),
                                              )
                                            : style,
                                      ),
                                    ),
                                    if (badges[i] != null) ...[
                                      const SizedBox(width: 6),
                                      badges[i]!,
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (i == selectedIndex)
                              Container(
                                width: 24,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

/// Kotlin's `ToolScaffold`: slim inline header (back, display-font title, optional add) above
/// the tool's content.
class ToolScaffold extends StatelessWidget {
  const ToolScaffold({
    super.key,
    required this.title,
    required this.onBack,
    required this.child,
    this.onAdd,
    this.addEnabled = true,
    this.keyPrefix = 'tool',
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback? onAdd;
  final bool addEnabled;
  final Widget child;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              IconButton(
                key: ValueKey('$keyPrefix.back'),
                tooltip: 'Back',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: OmniFonts.display,
                    fontWeight: OmniFonts.displayWeight,
                    fontSize: 18,
                  ),
                ),
              ),
              if (onAdd != null)
                IconButton(
                  key: ValueKey('$keyPrefix.add'),
                  tooltip: 'Add',
                  onPressed: addEnabled ? onAdd : null,
                  icon: Icon(
                    Icons.add,
                    color: addEnabled
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: 0.38),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Kotlin's `HostPickerField`: a compact field summarising the selection that opens a searchable
/// host list in a dialog, so selection stays visible however large the fleet grows.
class HostPickerField extends StatelessWidget {
  const HostPickerField({
    super.key,
    required this.label,
    required this.servers,
    required this.selectedIds,
    required this.onToggle,
    this.singleSelect = false,
    this.allHostsOption = false,
    this.isSelectable,
    this.onSelectAll,
    this.onClear,
    this.fieldKey,
  });

  final String label;
  final List<Server> servers;
  final Set<int> selectedIds;
  final ValueChanged<int> onToggle;
  final bool singleSelect;
  final bool allHostsOption;
  final bool Function(Server)? isSelectable;
  final VoidCallback? onSelectAll;
  final VoidCallback? onClear;
  final Key? fieldKey;

  String get _summary {
    if (allHostsOption && selectedIds.contains(0)) return 'All hosts';
    if (selectedIds.isEmpty) return 'Choose hosts…';
    final names = [
      for (final s in servers)
        if (selectedIds.contains(s.id)) s.name,
    ];
    if (singleSelect) return names.isEmpty ? 'Choose host…' : names.first;
    return '${names.length} selected: ${names.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(8);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: fieldKey,
        borderRadius: radius,
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => HostPickerDialog(
            title: label,
            servers: servers,
            initialSelected: selectedIds,
            onToggle: onToggle,
            singleSelect: singleSelect,
            allHostsOption: allHostsOption,
            isSelectable: isSelectable ?? (_) => true,
            onSelectAll: onSelectAll,
            onClear: onClear,
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: scheme.outline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                    ),
                    Text(
                      _summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontFamily: OmniFonts.mono),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_drop_down,
                color: OmniColors.cyan,
                semanticLabel: 'Choose hosts',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kotlin's `HostPickerDialog`. Selection is owned by the caller; the dialog mirrors it locally so
/// toggles are visible immediately.
class HostPickerDialog extends StatefulWidget {
  const HostPickerDialog({
    super.key,
    required this.title,
    required this.servers,
    required this.initialSelected,
    required this.onToggle,
    required this.singleSelect,
    required this.allHostsOption,
    required this.isSelectable,
    this.onSelectAll,
    this.onClear,
  });

  final String title;
  final List<Server> servers;
  final Set<int> initialSelected;
  final ValueChanged<int> onToggle;
  final bool singleSelect;
  final bool allHostsOption;
  final bool Function(Server) isSelectable;
  final VoidCallback? onSelectAll;
  final VoidCallback? onClear;

  @override
  State<HostPickerDialog> createState() => _HostPickerDialogState();
}

class _HostPickerDialogState extends State<HostPickerDialog> {
  late final Set<int> _selected = {...widget.initialSelected};
  String _query = '';

  void _toggle(int id) {
    widget.onToggle(id);
    if (widget.singleSelect) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.servers
        : widget.servers
              .where(
                (s) =>
                    s.name.toLowerCase().contains(q) ||
                    s.host.toLowerCase().contains(q) ||
                    (s.groupName ?? '').toLowerCase().contains(q),
              )
              .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.servers.length > 6) ...[
              TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  labelText: 'Search hosts',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (!widget.singleSelect && (widget.onSelectAll != null || widget.onClear != null))
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.onSelectAll != null)
                    InkWell(
                      onTap: () {
                        widget.onSelectAll!();
                        setState(() {
                          _selected
                            ..clear()
                            ..addAll(widget.servers.where(widget.isSelectable).map((s) => s.id));
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          'Select all',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  if (widget.onClear != null) ...[
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: () {
                        widget.onClear!();
                        setState(_selected.clear);
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Text(
                          'Clear',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: OmniColors.red,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (widget.allHostsOption && q.isEmpty)
                      _HostPickerRow(
                        name: 'All hosts',
                        detail: 'Applies to every saved host',
                        online: true,
                        dotColor: OmniColors.cyan,
                        checked: _selected.contains(0),
                        enabled: true,
                        singleSelect: widget.singleSelect,
                        onTap: () => _toggle(0),
                      ),
                    for (final s in filtered)
                      _HostPickerRow(
                        name: s.name,
                        detail:
                            '${HostDisplay.instance.userAtHost(s)}'
                            '${widget.isSelectable(s) ? '' : ' · offline'}',
                        online: s.status == 'online',
                        dotColor: OmniColors.serverAccent(s.serverColor, s.name),
                        checked: _selected.contains(s.id),
                        enabled: widget.isSelectable(s),
                        singleSelect: widget.singleSelect,
                        onTap: () => _toggle(s.id),
                      ),
                  ],
                ),
              ),
            ),
            if (filtered.isEmpty)
              Text(
                'No hosts match “$_query”.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }
}

class _HostPickerRow extends StatelessWidget {
  const _HostPickerRow({
    required this.name,
    required this.detail,
    required this.online,
    required this.dotColor,
    required this.checked,
    required this.enabled,
    required this.singleSelect,
    required this.onTap,
  });

  final String name;
  final String detail;
  final bool online;
  final Color dotColor;
  final bool checked;
  final bool enabled;
  final bool singleSelect;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            StatusDot(online: online, color: dotColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontFamily: OmniFonts.mono,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (singleSelect)
              RadioGroup<bool>(
                groupValue: checked ? true : null,
                onChanged: (_) => onTap(),
                child: Radio<bool>(value: true, enabled: enabled),
              )
            else
              Checkbox(value: checked, onChanged: enabled ? (_) => onTap() : null),
          ],
        ),
      ),
    );
  }
}

/// Kotlin's `OmniPasswordField`: an outlined password field with a show/hide eye toggle.
class OmniPasswordField extends StatefulWidget {
  const OmniPasswordField({
    super.key,
    required this.label,
    required this.onChanged,
    this.fieldKey,
    this.autofocus = false,
  });

  final String label;
  final ValueChanged<String> onChanged;
  final Key? fieldKey;
  final bool autofocus;

  @override
  State<OmniPasswordField> createState() => _OmniPasswordFieldState();
}

class _OmniPasswordFieldState extends State<OmniPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    autofocus: widget.autofocus,
    obscureText: !_visible,
    keyboardType: TextInputType.visiblePassword,
    onChanged: widget.onChanged,
    decoration: InputDecoration(
      labelText: widget.label,
      border: const OutlineInputBorder(),
      suffixIcon: IconButton(
        tooltip: _visible ? 'Hide password' : 'Show password',
        icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
        onPressed: () => setState(() => _visible = !_visible),
      ),
    ),
  );
}

/// Kotlin's `PrimaryScrollableTabRow`: a scrolling row of text tabs with the primary indicator
/// under the selected label and an outline-variant divider. [selectedIndex] stays owned by the
/// view model (so swipe paging and deep links move it); this widget only follows it.
class OmniScrollableTabRow extends StatefulWidget {
  const OmniScrollableTabRow({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.tabKeys,
    this.edgePadding = 0,
    this.fontWeight,
    this.contentTabs = false,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<Key>? tabKeys;

  /// Kotlin's `edgePadding`: Monitor uses 12dp, Network and Infra 0.
  final double edgePadding;
  final FontWeight? fontWeight;

  /// Kotlin's `Tab { Text(…, padding(vertical = 8.dp)) }` form (Monitor, Infra), which is only as
  /// tall as its label; `Tab(text = …)` (Network) keeps Material's 48dp.
  final bool contentTabs;

  @override
  State<OmniScrollableTabRow> createState() => _OmniScrollableTabRowState();
}

class _OmniScrollableTabRowState extends State<OmniScrollableTabRow>
    with SingleTickerProviderStateMixin {
  late TabController _controller = _create();

  TabController _create() => TabController(
    length: widget.labels.length,
    initialIndex: widget.selectedIndex.clamp(0, widget.labels.length - 1),
    vsync: this,
  );

  @override
  void didUpdateWidget(OmniScrollableTabRow old) {
    super.didUpdateWidget(old);
    if (old.labels.length != widget.labels.length) {
      _controller.dispose();
      _controller = _create();
    } else if (_controller.index != widget.selectedIndex) {
      _controller.animateTo(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Tab's text keeps titleSmall's 20sp line height when Kotlin shrinks it to Dense.
    final style = (Theme.of(context).textTheme.titleSmall ?? const TextStyle()).copyWith(
      fontSize: OmniTextSize.dense,
      height: 20 / OmniTextSize.dense,
      leadingDistribution: TextLeadingDistribution.even,
      fontWeight: widget.fontWeight,
    );
    return TabBar(
      controller: _controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: EdgeInsets.symmetric(horizontal: widget.edgePadding),
      dividerColor: scheme.outlineVariant,
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.primary,
      labelStyle: style,
      unselectedLabelStyle: style,
      indicatorSize: TabBarIndicatorSize.label,
      onTap: widget.onSelected,
      tabs: [
        for (var i = 0; i < widget.labels.length; i++)
          Tab(
            key: widget.tabKeys?[i],
            height: widget.contentTabs ? null : 48,
            // Compose's ScrollableTabRow gives every tab at least 90dp, padding included
            // (Flutter adds 16dp label padding either side).
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 90 - 32),
              child: Center(
                widthFactor: 1,
                child: widget.contentTabs
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(widget.labels[i]),
                      )
                    : Text(widget.labels[i]),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lets a `Column` with `Expanded` parts survive a very short window (landscape at large text):
/// below [minHeight] × the text scale it scrolls the whole column at that height, so the fixed
/// chrome stays reachable and the expanding list keeps usable room, instead of overflowing.
class ShortViewportScroll extends StatelessWidget {
  const ShortViewportScroll({super.key, required this.child, this.minHeight = 360});

  final Widget child;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final needed = minHeight * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxHeight >= needed
          ? child
          : SingleChildScrollView(
              child: SizedBox(height: needed, child: child),
            ),
    );
  }
}
