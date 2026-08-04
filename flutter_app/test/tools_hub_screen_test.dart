import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/tools/about_screen.dart';
import 'package:omniterm/ui/screens/tools/tools_hub_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:provider/provider.dart';

void main() {
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

  group('the hub', () {
    testWidgets('offers every tool screen', (tester) async {
      await pump(tester, const ToolsHubScreen());

      for (final (screen, label, _) in ToolsHubScreen.tools) {
        expect(find.byKey(ValueKey('tools.${screen.name}')), findsOneWidget, reason: screen.name);
        expect(find.text(label), findsOneWidget, reason: label);
      }
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
    testWidgets('states plainly where data goes', (tester) async {
      // This is the claim the app asks to be trusted on, so it is specific and checkable rather
      // than a vague reassurance.
      await pump(tester, const AboutScreen());

      expect(find.byKey(const ValueKey('about.privacy')), findsOneWidget);
      expect(find.textContaining('stay on this device'), findsOneWidget);
      expect(find.textContaining('no telemetry'), findsOneWidget);
      await tester.pump();
    });

    testWidgets('names the licence and shows the source link', (tester) async {
      await pump(tester, const AboutScreen());

      expect(find.textContaining('PolyForm Noncommercial'), findsOneWidget);
      expect(find.text(AboutScreen.projectUrl), findsOneWidget);
      await tester.pump();
    });

    testWidgets('the diagnostics block carries nothing identifying', (tester) async {
      // A user is invited to paste this into a public issue, so it must be safe to paste there.
      await pump(tester, const AboutScreen());

      final text = tester
          .widget<Text>(find.byKey(const ValueKey('about.diagnostics.text')))
          .data!;
      expect(text, contains('OmniTerm'));
      expect(text, contains('Platform:'));
      expect(text.toLowerCase(), isNot(contains('password')));
      expect(text.toLowerCase(), isNot(contains('@')), reason: 'no user@host anywhere');
      expect(find.textContaining('no host names, addresses or credentials'), findsOneWidget);
      await tester.pump();
    });

    testWidgets('copying reports what was copied', (tester) async {
      // The link cannot be opened until the platform integration lands, so copying has to be
      // visibly successful rather than appearing to do nothing.
      final copied = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await pump(tester, const AboutScreen());
      await tester.tap(find.byKey(const ValueKey('about.copyUrl')));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      expect(
        (copied.single.arguments as Map)['text'],
        AboutScreen.projectUrl,
      );
      expect(find.byKey(const ValueKey('about.copied')), findsOneWidget);
      await tester.pump();
    });

    testWidgets('a missing version does not blank the screen', (tester) async {
      // PackageInfo needs a platform channel that a plain widget test does not provide.
      await pump(tester, const AboutScreen());
      expect(find.byKey(const ValueKey('about.version')), findsOneWidget);
      await tester.pump();
    });
  });
}
