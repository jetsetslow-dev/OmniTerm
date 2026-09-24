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

  testWidgets('every metric gets six fields, seeded from the saved config', (tester) async {
    await pump(tester);

    for (final metric in HealthMetric.values) {
      expect(find.byKey(ValueKey('healthScoring.metric.${metric.name}')), findsOneWidget);
      for (final tier in ['warn', 'high', 'critical']) {
        expect(find.byKey(ValueKey('healthScoring.${metric.name}.${tier}At')), findsOneWidget);
        expect(find.byKey(ValueKey('healthScoring.${metric.name}.${tier}Penalty')), findsOneWidget);
      }
    }
    await finish(tester);
  });

  testWidgets('the preview shows a score and what deducted from it', (tester) async {
    // The numbers in this form are abstract until you see what they do.
    await pump(tester);

    expect(find.byKey(const ValueKey('healthScoring.preview.score')), findsOneWidget);
    // The breakdown line, not the slider's own label: it names the tier and the threshold crossed.
    expect(find.textContaining('CPU 60% — elevated'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('editing a penalty changes the preview immediately', (tester) async {
    await pump(tester);
    final before = vm
        .previewFor(cpuPercent: 60, memoryPercent: 75, diskPercent: 85, latencyMs: 60)!
        .score;

    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnPenalty')), '40');
    await tester.pumpAndSettle();

    final after = vm
        .previewFor(cpuPercent: 60, memoryPercent: 75, diskPercent: 85, latencyMs: 60)!
        .score;
    expect(after, lessThan(before));
    await finish(tester);
  });

  testWidgets('out-of-order thresholds are flagged on the metric and block saving', (tester) async {
    // The middle tier would be unreachable, so the metric would silently stop scoring.
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '99');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('healthScoring.metric.cpu.error')), findsOneWidget);
    expect(find.textContaining('must increase'), findsWidgets);

    final save = tester.widget<FilledButton>(find.byKey(const ValueKey('healthScoring.save')));
    expect(save.onPressed, isNull);
    await finish(tester);
  });

  testWidgets('an empty field says required rather than invalid', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('healthScoring.disk.highAt')), '');
    await tester.pumpAndSettle();

    expect(find.textContaining('required'), findsWidgets);
    await finish(tester);
  });

  testWidgets('the preview is withheld while the draft is unusable', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('healthScoring.preview.score')), findsNothing);
    expect(find.textContaining('Fix the values below'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('saving persists and confirms', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '40');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('healthScoring.save')));
    await tester.pumpAndSettle();

    expect(vm.saved.cpu.warnAt, 40);
    expect(find.textContaining('Saved'), findsOneWidget);
    expect(
      HealthScoringConfig.decode(
        await repo.getSetting(HealthScoringViewModel.settingKey),
      ).cpu.warnAt,
      40,
    );
    await finish(tester);
  });

  testWidgets('discard appears only when dirty and puts the fields back', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('healthScoring.revert')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('healthScoring.cpu.warnAt')), '40');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('healthScoring.revert')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('healthScoring.revert')));
    await tester.pumpAndSettle();

    expect(vm.isDirty, isFalse);
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('healthScoring.cpu.warnAt')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.controller.text, '50', reason: 'the field must follow the discarded draft');
    await finish(tester);
  });

  testWidgets('resetting asks first and says what is lost', (tester) async {
    await repo.insertSetting(
      HealthScoringViewModel.settingKey,
      const HealthScoringConfig(cpu: MetricTiers(10, 20, 30, 1, 2, 3)).encode(),
    );
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('healthScoring.reset')));
    await tester.pumpAndSettle();
    expect(find.textContaining('your tuning is lost'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('healthScoring.reset.cancel')));
    await tester.pumpAndSettle();
    expect(vm.saved.cpu.warnAt, 10);

    await tester.tap(find.byKey(const ValueKey('healthScoring.reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('healthScoring.reset.confirm')));
    await tester.pumpAndSettle();

    expect(vm.saved, HealthScoringConfig.defaults);
    await finish(tester);
  });
}
