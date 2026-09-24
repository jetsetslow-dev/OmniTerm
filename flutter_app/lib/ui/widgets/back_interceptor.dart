import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation.dart';

/// Claims the Android Back press for as long as this widget is mounted.
///
/// The app installs a single root-level [PopScope] (`main.dart`), so a screen that wants Back to
/// mean something local cannot simply add its own — it has to say so before the root handler runs.
/// [NavigationController.guards] is that hook, and this widget is the screen-side half of it: it
/// registers [onBack] on mount and removes it on dispose, so a screen that is no longer shown can
/// never keep swallowing Back.
///
/// [onBack] returns true when it consumed the press. Returning false lets the press fall through
/// to the next guard and ultimately to app navigation, which is what a screen with nothing left to
/// unwind should do.
///
/// Only back presses reach [onBack]. Guards are also consulted for forward navigation, where the
/// requested screen is non-null; a tab tap must not silently unwind another screen's state.
class BackInterceptor extends StatefulWidget {
  const BackInterceptor({super.key, required this.onBack, required this.child});

  final bool Function() onBack;
  final Widget child;

  @override
  State<BackInterceptor> createState() => _BackInterceptorState();
}

class _BackInterceptorState extends State<BackInterceptor> {
  NavigationController? _nav;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.read<NavigationController>();
    if (identical(nav, _nav)) return;
    _nav?.guards.remove(_guard);
    _nav = nav;
    nav.guards.add(_guard);
  }

  // `to == null` is what NavigationController.navigateBack passes; anything else is a forward
  // navigation this widget has no opinion about.
  bool _guard(Screen from, Screen? to) => to == null && widget.onBack();

  @override
  void dispose() {
    _nav?.guards.remove(_guard);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
