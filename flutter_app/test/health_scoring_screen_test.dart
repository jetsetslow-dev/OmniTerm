import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/health_scoring.dart';
import 'package:omniterm/domain/health_tier_form.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/health_scoring_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/health_scoring_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late HealthScoringViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    // Twenty-four fields plus a preview do not fit the default 800x600 surface, so anything below
    // the fold would never be laid out for a finder to see.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = HealthScoringViewModel(app);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<HealthScoringViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: HealthScoringScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  String fieldText(WidgetTester tester, String key) => tester
      .widget<EditableText>(
        find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)),
      )
      .controller
      .text;

  testWidgets('one Kotlin card holds six fields per metric, seeded from the config', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Health scoring'), findsNWidgets(2), reason: 'scaffold title and card title');
    expect(find.text('CPU · threshold (%) then penalty'), findsOneWidget);
    expect(find.text('Latency · threshold (ms) then penalty'), findsOneWidget);
    for (final metric in HealthMetric.values) {
      for (final tier in ['warn', 'high', 'critical']) {
        expect(find.byKey(ValueKey('healthScoring.${metric.name}.${tier}At')), findsOneWidget);
        expect(find.byKey(ValueKey('healthScoring.${metric.name}.${tier}Penalty')), findsOneWidget);
      }
    }
    expect(fieldText(tester, 'healthScoring.cpu.warnAt'), '50');
    expect(find.text('warn ≥'), findsNWidgets(4));
    expect(find.text('-pts'), findsNWidgets(12));
    await finish(tester);
  });

  testWidgets('fields accept only digits and a decimal point', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '4a5.5x');
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'healthScoring.cpu.warnAt'), '45.5');
    await finish(tester);
  });

  testWidgets('out-of-order thresholds show Kotlin\'s message and block saving', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '95');
    await tester.pumpAndSettle();

    expect(find.text('Thresholds must increase: warn <= high <= crit'), findsOneWidget);
    final save = tester.widget<FilledButton>(find.byKey(const ValueKey('healthScoring.save')));
    expect(save.onPressed, isNull);
    await finish(tester);
  });

  testWidgets('an empty field says Required, and latency wants whole milliseconds', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('healthScoring.memory.highAt')), '');
    await tester.enterText(find.byKey(const ValueKey('healthScoring.latency.warnAt')), '50.5');
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Must be a whole number'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('saving asks first, then persists', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '40');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('healthScoring.save')));
    await tester.pumpAndSettle();
    expect(find.text('Save scoring config?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('healthScoring.save.confirm')));
    await tester.pumpAndSettle();

    expect(vm.saved.cpu.warnAt, 40);
    expect(
      HealthScoringConfig.decode(
        await repo.getSetting(HealthScoringViewModel.settingKey),
      ).cpu.warnAt,
      40,
    );
    await finish(tester);
  });

  testWidgets('Save scoring is enabled with nothing changed, as in Kotlin', (tester) async {
    await pump(tester);
    final save = tester.widget<FilledButton>(find.byKey(const ValueKey('healthScoring.save')));
    expect(save.onPressed, isNotNull);
    await finish(tester);
  });

  testWidgets('a decimal penalty keeps the default penalty, as Kotlin does', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnPenalty')), '7.5');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('healthScoring.save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('healthScoring.save.confirm')));
    await tester.pumpAndSettle();
    expect(vm.saved.cpu.warnPenalty, HealthScoringConfig.defaults.cpu.warnPenalty);
    await finish(tester);
  });

  testWidgets('resetting asks with Kotlin wording first', (tester) async {
    await repo.insertSetting(
      HealthScoringViewModel.settingKey,
      const HealthScoringConfig(cpu: MetricTiers(10, 20, 30, 1, 2, 3)).encode(),
    );
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('healthScoring.reset')));
    await tester.pumpAndSettle();
    expect(find.text('Reset to defaults?'), findsOneWidget);
    expect(find.textContaining('This cannot be undone.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('healthScoring.reset.cancel')));
    await tester.pumpAndSettle();
    expect(vm.saved.cpu.warnAt, 10);

    await tester.tap(find.byKey(const ValueKey('healthScoring.reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('healthScoring.reset.confirm')));
    await tester.pumpAndSettle();

    expect(vm.saved, HealthScoringConfig.defaults);
    expect(fieldText(tester, 'healthScoring.cpu.warnAt'), '50');
    await finish(tester);
  });
}
