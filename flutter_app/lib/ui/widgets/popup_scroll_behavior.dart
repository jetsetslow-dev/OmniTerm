import 'package:flutter/material.dart';

/// Give every dialog and modal sheet scroll viewport a persistent overflow cue.
/// Uses that viewport's own controller, never a shared primary controller.
class PopupScrollBehavior extends MaterialScrollBehavior {
  const PopupScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (ModalRoute.of(context) is! PopupRoute) {
      return super.buildScrollbar(context, child, details);
    }
    return _PopupOverflow(
      controller: details.controller!,
      direction: details.direction,
      child: child,
    );
  }
}

class _PopupOverflow extends StatefulWidget {
  const _PopupOverflow({required this.controller, required this.direction, required this.child});
  final ScrollController controller;
  final AxisDirection direction;
  final Widget child;

  @override
  State<_PopupOverflow> createState() => _PopupOverflowState();
}

class _PopupOverflowState extends State<_PopupOverflow> {
  bool _queued = false;

  void _metricsChanged() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0) _metricsChanged();
        return false;
      },
      child: AnimatedBuilder(
        animation: widget.controller,
        child: widget.child,
        builder: (context, child) {
          final positions = widget.controller.positions;
          final position = positions.length == 1 ? positions.single : null;
          final above =
              position != null && position.hasContentDimensions && position.extentBefore > 1;
          final below =
              position != null && position.hasContentDimensions && position.extentAfter > 1;
          return Stack(
            fit: StackFit.passthrough,
            children: [child!, if (above) _hint(context, true), if (below) _hint(context, false)],
          );
        },
      ),
    );
  }

  Widget _hint(BuildContext context, bool before) {
    final direction = before ? flipAxisDirection(widget.direction) : widget.direction;
    final label = switch (direction) {
      AxisDirection.up => '↑ More above',
      AxisDirection.down => '↓ More below',
      AxisDirection.left => '← More left',
      AxisDirection.right => '→ More right',
    };
    return Positioned(
      top: direction == AxisDirection.up ? 0 : null,
      bottom: direction == AxisDirection.up ? null : 0,
      left: direction == AxisDirection.left ? 4 : null,
      right: direction == AxisDirection.left ? null : 4,
      child: IgnorePointer(
        child: Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
