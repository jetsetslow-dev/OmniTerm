import 'package:flutter/material.dart';

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
  });

  final Widget child;
  final Color? leftAccent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(leftAccent != null ? 4 : 10);

    Widget card = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: radius,
        border: Border.all(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Padding(padding: const EdgeInsets.all(12), child: child),
          if (leftAccent != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(color: leftAccent!),
            ),
        ],
      ),
    );

    if (onTap != null || onLongPress != null) {
      card = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: radius,
          child: card,
        ),
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
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small uppercase heading above a list section.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
              fontSize: 11,
              letterSpacing: 1.1,
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
  Widget? prefixIcon,
  Widget? suffixIcon,
}) {
  final scheme = Theme.of(context).colorScheme;
  return InputDecoration(
    hintText: hintText,
    labelText: labelText,
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

/// Compact uptime, ported from `formatUptime`.
String formatUptime(int seconds) {
  if (seconds <= 0) return '—';
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
