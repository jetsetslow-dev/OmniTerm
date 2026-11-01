import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/theme/typography.dart';
import 'package:omniterm/ui/widgets/omni_components.dart';

import 'support/material_fonts.dart';

/// Pins the Compose metrics the Kotlin screens are built from, which Flutter's defaults differ on.
void main() {
  setUpAll(loadMaterialRoboto);

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );

  testWidgets('an 11sp caption sits on a 24sp line, as Compose bodyLarge keeps it', (tester) async {
    await pump(
      tester,
      Text('One line', key: const ValueKey('t'), style: composeBody(fontSize: 11)),
    );
    expect(tester.getSize(find.byKey(const ValueKey('t'))).height, 24);
  });

  testWidgets('a content tab row is label-tall (36dp) like Kotlin, not 48dp', (tester) async {
    await pump(
      tester,
      SizedBox(
        width: 360,
        child: OmniTabRow(labels: const ['Active', 'Rules'], selectedIndex: 0, onSelected: (_) {}),
      ),
    );
    // 20sp label line + 8dp above and below, then the 1dp divider.
    expect(tester.getSize(find.byType(OmniTabRow)).height, 37);
  });

  testWidgets('scrollable tabs are at least 90dp wide, as Compose ScrollableTabRow', (
    tester,
  ) async {
    await pump(
      tester,
      SizedBox(
        width: 360,
        child: OmniScrollableTabRow(
          labels: const ['Ping', 'DNS'],
          selectedIndex: 0,
          onSelected: (_) {},
          tabKeys: const [ValueKey('a'), ValueKey('b')],
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const ValueKey('a'))).width, greaterThanOrEqualTo(90 - 32));
    expect(tester.getSize(find.byType(Tab).first).height, 48);
  });
}
