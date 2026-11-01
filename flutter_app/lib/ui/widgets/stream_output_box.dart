import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// A ping output line that reports a failure, as Kotlin's `isPingFailureLine`.
bool isPingFailureLine(String line) {
  final lower = line.toLowerCase();
  return lower.contains('failed') ||
      lower.contains('unreachable') ||
      line.contains('100% packet loss');
}

/// A traceroute output line that reports a failure, as Kotlin's `isTracerouteFailureLine`.
bool isTracerouteFailureLine(String line) {
  final lower = line.toLowerCase();
  return lower.contains('not available') || lower.contains('failed');
}

/// Streamed command output, as Kotlin's `StreamOutputBox` with `failureHighlighted`: monospace and
/// selectable, following the newest line, with the lines [isFailure] picks out in red. Ping and
/// traceroute use it in Tools and in the Hosts tab's host check.
///
/// [placeholder] shows while there is no output yet. Callers size and frame it; with [shrinkWrap]
/// it is only as tall as its lines, within the caller's limits.
class StreamOutputBox extends StatefulWidget {
  const StreamOutputBox({
    super.key,
    required this.lines,
    this.isFailure,
    this.placeholder,
    this.padding = const EdgeInsets.all(10),
    this.shrinkWrap = false,
  });

  final List<String> lines;
  final bool Function(String line)? isFailure;
  final String? placeholder;
  final EdgeInsets padding;
  final bool shrinkWrap;

  @override
  State<StreamOutputBox> createState() => _StreamOutputBoxState();
}

class _StreamOutputBoxState extends State<StreamOutputBox> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(StreamOutputBox old) {
    super.didUpdateWidget(old);
    if (widget.lines.length != old.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = widget.placeholder;
    if (widget.lines.isEmpty && placeholder != null) {
      return Padding(
        padding: widget.padding,
        child: Text(
          placeholder,
          style: composeBody(
            fontSize: 11,
            fontFamily: OmniFonts.mono,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return SelectionArea(
      child: ListView.separated(
        controller: _scroll,
        shrinkWrap: widget.shrinkWrap,
        padding: widget.padding,
        itemCount: widget.lines.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (_, i) {
          final line = widget.lines[i];
          return Text(
            line,
            style: composeBody(
              fontSize: 11,
              fontFamily: OmniFonts.mono,
              color: widget.isFailure?.call(line) == true ? OmniColors.red : scheme.onSurface,
            ),
          );
        },
      ),
    );
  }
}
