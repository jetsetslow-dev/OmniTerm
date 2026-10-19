import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/l10n/app_localizations.dart';

/// The Flutter app's text is generated from the Kotlin app's string resources. These pin that the
/// pipeline is wired (the delegate loads) and that a message carries Kotlin's exact wording,
/// including a format resource whose `%1$s` / `%2$s` placeholders became arguments.
void main() {
  testWidgets('app text loads from the generated Kotlin catalogue', (tester) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(l10n.saveAnyway, 'Save anyway');
    expect(
      l10n.duplicateHostBody('nas', '10.0.0.5'),
      'Host nas already uses 10.0.0.5. A different SSH user, authentication method or port is a '
      'separate connection. A different display name alone is not.',
    );
  });

  test('every Kotlin string resource is in the Flutter template', () {
    final xml = File('../app/src/main/res/values/strings.xml').readAsStringSync();
    final arb = File('lib/l10n/app_en.arb').readAsStringSync();
    final names = RegExp(r'<string name="([a-z0-9_]+)"').allMatches(xml).map((m) => m.group(1)!);
    String camel(String n) {
      final parts = n.split('_');
      return parts.first +
          parts.skip(1).map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1)).join();
    }

    final missing = [
      for (final name in names)
        if (!arb.contains('"${camel(name)}":') && !arb.contains('"${camel(name)}_":')) name,
    ];
    expect(missing, isEmpty, reason: 'regenerate with scripts/generate-flutter-strings.py');
  });
}
