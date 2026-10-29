import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the pinned Flutter SDK's Material Roboto so layout tests measure text the way an
/// Android device does. The default test font draws every glyph one em wide, which wraps large
/// text far more than a phone and makes text-scale guards measure the wrong layout.
Future<void> loadMaterialRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('FLUTTER_ROOT is not set for this test run');
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final name in ['Roboto-Regular', 'Roboto-Medium', 'Roboto-Bold']) {
    final bytes = File('$dir/$name.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}
