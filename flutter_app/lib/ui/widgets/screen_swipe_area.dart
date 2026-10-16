import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Deliberate horizontal paging, matching Kotlin's `Modifier.swipeTabs`.
///
/// Distance, not release velocity, makes a paused/slow swipe work. The horizontal recognizer
/// still competes normally with descendant scrollables; this must not intercept their pointers.
class ScreenSwipeArea extends StatefulWidget {
  const ScreenSwipeArea({super.key, required this.onSwipe, required this.child});

  final ValueChanged<bool> onSwipe;
  final Widget child;

  @override
  State<ScreenSwipeArea> createState() => _ScreenSwipeAreaState();
}

class _ScreenSwipeAreaState extends State<ScreenSwipeArea> {
  Offset? _origin;
  bool _fired = false;

  void _reset() {
    _origin = null;
    _fired = false;
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    // Include the touch-slop distance; a coarse first event must not swallow most of a swipe.
    dragStartBehavior: DragStartBehavior.down,
    onHorizontalDragStart: (details) {
      _origin = details.globalPosition;
      _fired = false;
    },
    onHorizontalDragUpdate: (details) {
      final origin = _origin;
      if (origin == null || _fired) return;
      final distance = details.globalPosition - origin;
      // Flutter logical pixels and Android dp share this density-independent threshold.
      if (distance.dx.abs() > 96 && distance.dx.abs() > distance.dy.abs() * 2.2) {
        // Set before notifying: navigation can rebuild this widget during the same gesture.
        _fired = true;
        widget.onSwipe(distance.dx < 0);
      }
    },
    onHorizontalDragEnd: (_) => _reset(),
    onHorizontalDragCancel: _reset,
    child: widget.child,
  );
}
