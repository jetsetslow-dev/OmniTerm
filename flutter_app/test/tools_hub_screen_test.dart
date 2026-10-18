import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/tools/about_screen.dart';
import 'package:omniterm/ui/screens/tools/tools_hub_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:provider/provider.dart';

import 'support/material_fonts.dart';

void main() {
  setUpAll(loadMaterialRoboto);

  late NavigationController navigation;

  setUp(() => navigation = NavigationController());
  tearDown(() => navigation.dispose());

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationController>.value(
        value: navigation,
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('tile size', () {
    Future<void> pumpPhone(WidgetTester tester, double textScale) async {
      // The API 35 device profile's portrait width, where 150% text first wrapped a label past
      // Kotlin's fixed tile.
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<NavigationController>.value(
          value: navigation,
          child: MaterialApp(
            theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 740),
                textScaler: TextScaler.linear(textScale),
              ),
              child: const Scaffold(body: ToolsHubScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tiles are Kotlin\'s 110dp at normal text', (tester) async {
      await pumpPhone(tester, 1);
      for (final (screen, _, _) in ToolsHubScreen.tools) {
        expect(tester.getSize(find.byKey(ValueKey('tools.${screen.name}'))).height, 110);
      }
    });

    for (final scale in const [1.3, 1.5, 1.75, 2.0]) {
      testWidgets('no label overflows its tile at ${(scale * 100).round()}% text', (tester) async {
        await pumpPhone(tester, scale);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the hub', () {
    testWidgets('offers every tool screen', (tester) async {
      await pump(tester, const ToolsHubScreen());

      for (final (screen, label, _) in ToolsHubScreen.tools) {
        expect(find.byKey(ValueKey('tools.${screen.name}')), findsOneWidget, reason: screen.name);
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.pump();
    });

    testWidgets('every tile carries the Kotlin label, verbatim', (tester) async {
      // Sentence case on both sides. Kotlin's casing was inconsistent — "Crash history" beside
      // "OmniTerm Utilities" — so the fix was to normalise *both* implementations rather than copy
      // the inconsistency into Flutter; the Kotlin half is in the parity branch. Pinned here
      // because nothing asserted these labels before, which is how they drifted unnoticed.
      await pump(tester, const ToolsHubScreen());

      for (final label in const [
        'Alerts & rules',
        'Scripts',
        'Network tools',
        'Auth & keys',
        'App backup',
        'Health scoring',
        'Settings',
        'About OmniTerm',
      ]) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: '$label must match the Kotlin label exactly',
        );
      }
      expect(find.text('OmniTerm utilities'), findsOneWidget);
      await tester.pump();
    });

    testWidgets('tapping a tile navigates there', (tester) async {
      await pump(tester, const ToolsHubScreen());

      await tester.tap(find.byKey(const ValueKey('tools.alerts')));
      await tester.pumpAndSettle();
      expect(navigation.currentScreen, Screen.alerts);
      await tester.pump();
    });

    testWidgets('every tile targets a distinct screen', (tester) async {
      // A duplicated target would make one tool unreachable while looking present.
      final targets = ToolsHubScreen.tools.map((t) => t.$1).toList();
      expect(targets.toSet().length, targets.length);
      await pump(tester, const ToolsHubScreen());
      await tester.pump();
    });
  });

  group('About', () {
    testWidgets('states plainly where data goes, in Kotlin words', (tester) async {
      await pump(tester, const AboutScreen());

      expect(find.text('About OmniTerm'), findsOneWidget);
      expect(find.text('OmniTerm Terminal Console'), findsOneWidget);
      final privacy = tester.widget<Text>(find.byKey(const ValueKey('about.privacy'))).data!;
      expect(privacy, startsWith('Source Available build.'));
      expect(privacy, contains('keeps SSH keys and credentials on-device'));
      expect(privacy, contains('no OmniTerm account or usage telemetry'));
      expect(
        privacy,
        endsWith(
          'Source builds do not include Google billing, ads, consent, or in-app review services.',
        ),
      );
      await tester.pump();
    });

    testWidgets('names the licence and shows the source link', (tester) async {
      await pump(tester, const AboutScreen());

      expect(find.textContaining('PolyForm Noncommercial'), findsOneWidget);
      expect(find.text(AboutScreen.projectUrl), findsOneWidget);
      expect(find.text('View on GitHub'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      await tester.pump();
    });

    testWidgets('copied diagnostics carry nothing identifying', (tester) async {
      // A user is invited to paste this into a public issue, so it must be safe to paste there.
      final copied = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copied.add(call);
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pump(tester, const AboutScreen());
      final copy = find.byKey(const ValueKey('about.copyDiagnostics'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();

      final text = (copied.single.arguments as Map)['text'] as String;
      expect(text, startsWith('App version: '));
      expect(text, contains('\nDevice: '));
      expect(text, contains('\nABI: '));
      expect(text, endsWith('\nAd ID: N/A'));
      expect(text.toLowerCase(), isNot(contains('@')), reason: 'no user@host anywhere');
      expect(find.text('Diagnostics copied to clipboard.'), findsOneWidget);
      await tester.pump();
    });

    testWidgets('the diagnostics rows follow Kotlin', (tester) async {
      await pump(tester, const AboutScreen());
      for (final label in [
        'App version',
        'Build',
        'Distribution',
        'Device',
        'Android',
        'ABI',
        'Ad ID',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Source Available'), findsOneWidget);
      expect(
        find.text('No crashes recorded. Reports appear here automatically if the app crashes.'),
        findsOneWidget,
      );
      await tester.pump();
    });

    testWidgets('a missing version does not blank the screen', (tester) async {
      // PackageInfo needs a platform channel that a plain widget test does not provide.
      await pump(tester, const AboutScreen());
      expect(find.byKey(const ValueKey('about.version')), findsOneWidget);
      expect(find.text('Version …'), findsOneWidget);
      await tester.pump();
    });
  });
}
