import 'package:flutter/widgets.dart';

/// For a form's [State] that owns its text fields: rebuilds whenever one of [textControllers]
/// changes, so a Save button that depends on the text stays current, and disposes them with it.
mixin TextControllersState<T extends StatefulWidget> on State<T> {
  List<TextEditingController> get textControllers;

  @override
  void initState() {
    super.initState();
    for (final c in textControllers) {
      c.addListener(_onTextChanged);
    }
  }

  void _onTextChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in textControllers) {
      c
        ..removeListener(_onTextChanged)
        ..dispose();
    }
    super.dispose();
  }
}
