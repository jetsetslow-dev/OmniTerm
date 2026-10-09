import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/health_scoring.dart';
import 'package:omniterm/domain/health_tier_form.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/health_scoring_view_model.dart';

import 'support/fake_secure_storage.dart';

/// Thresholds that do not ascend make a tier unreachable, so the metric silently stops deducting
/// and a struggling host keeps reporting 100. That is the failure these tests exist to prevent.
void main() {
  TierFields fields({
    String warn = '50',
    String high = '75',
    String critical = '90',
    String warnPenalty = '5',
    String highPenalty = '15',
    String criticalPenalty = '30',
  }) => TierFields(
    warnAt: warn,
    highAt: high,
    criticalAt: critical,
    warnPenalty: warnPenalty,
    highPenalty: highPenalty,
    criticalPenalty: criticalPenalty,
  );

  group('validation', () {
    test('the defaults are valid', () {
      final form = fieldsFrom(HealthScoringConfig.defaults);
      expect(validateAll(form), isNull);
      expect(configFrom(form), HealthScoringConfig.defaults);
    });

    test('an empty field says it is required, not that it is wrong', () {
      // "Must be a number" reads as though what was typed was invalid, when nothing was typed.
      expect(validateTier(fields(warn: ''), HealthMetric.cpu), contains('required'));
      expect(validateTier(fields(warnPenalty: '  '), HealthMetric.cpu), contains('required'));
    });

    test('non-numeric text is reported', () {
      expect(validateTier(fields(high: 'lots'), HealthMetric.cpu), contains('must be a number'));
    });

    test('a percentage cannot exceed 100', () {
      expect(
        validateTier(fields(critical: '150'), HealthMetric.cpu),
        contains('between 0 and 100'),
      );
    });

    test('latency may exceed 100, since milliseconds have no ceiling at 100', () {
      expect(
        validateTier(fields(warn: '50', high: '100', critical: '2000'), HealthMetric.latency),
        isNull,
      );
    });

    test('latency still has an upper bound', () {
      expect(
        validateTier(fields(warn: '50', high: '100', critical: '9999999'), HealthMetric.latency),
        contains('between'),
      );
    });

    test('out-of-order thresholds are refused', () {
      // The middle tier would be unreachable and the metric would quietly stop scoring.
      expect(
        validateTier(fields(warn: '90', high: '75', critical: '95'), HealthMetric.cpu),
        contains('must increase'),
      );
      expect(
        validateTier(fields(warn: '50', high: '95', critical: '75'), HealthMetric.cpu),
        contains('must increase'),
      );
    });

    test('equal thresholds are allowed', () {
      // Collapsing two tiers into one is a legitimate choice — it means "go straight to critical".
      expect(
        validateTier(fields(warn: '90', high: '90', critical: '90'), HealthMetric.cpu),
        isNull,
      );
    });

    test('a penalty of zero is allowed, so a metric can be ignored', () {
      expect(
        validateTier(
          fields(warnPenalty: '0', highPenalty: '0', criticalPenalty: '0'),
          HealthMetric.cpu,
        ),
        isNull,
      );
    });

    test('a penalty above 100 is refused', () {
      // The score starts at 100, so a larger penalty is meaningless.
      expect(
        validateTier(fields(criticalPenalty: '400'), HealthMetric.cpu),
        contains('between 0 and 100'),
      );
    });

    test('the first problem is reported, in reading order', () {
      // Six errors at once under a form is noise rather than guidance.
      final error = validateTier(fields(warn: '', high: 'x', critical: '200'), HealthMetric.cpu);
      expect(error, contains('Warn threshold'));
    });

    test('validateAll names the metric that failed', () {
      final form = fieldsFrom(HealthScoringConfig.defaults);
      form[HealthMetric.disk]!.warnAt = '';
      expect(validateAll(form), startsWith('Disk'));
    });

    test('a whitespace-padded value is accepted', () {
      expect(validateTier(fields(warn: '  50  '), HealthMetric.cpu), isNull);
    });
  });

  group('round trip', () {
    test('fields survive config → text → config', () {
      const config = HealthScoringConfig(
        cpu: MetricTiers(40, 60, 80, 3, 9, 21),
        mem: MetricTiers(55, 70, 85, 4, 11, 22),
        disk: MetricTiers(70, 85, 95, 8, 20, 35),
        latency: MetricTiers(25, 90, 400, 2, 6, 18),
      );
      expect(configFrom(fieldsFrom(config)), config);
    });

    test('thresholds render without a trailing .0', () {
      // "50.0" in a text field invites someone to type over the decimal point.
      final form = fieldsFrom(HealthScoringConfig.defaults);
      expect(form[HealthMetric.cpu]!.warnAt, '50');
      expect(form[HealthMetric.cpu]!.warnAt, isNot(contains('.')));
    });

    test('an unusable form produces no config', () {
      final form = fieldsFrom(HealthScoringConfig.defaults);
      form[HealthMetric.cpu]!.highAt = 'nope';
      expect(configFrom(form), isNull);
    });
  });

  group('the editor', () {
    late AppDatabase db;
    late AppRepository repo;
    late AppState app;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      app = AppState(repo);
    });

    tearDown(() async {
      app.dispose();
      await db.close();
    });

    Future<HealthScoringViewModel> boot() async {
      await app.start();
      final vm = HealthScoringViewModel(app);
      await vm.start();
      return vm;
    }

    test('starts from the saved config', () async {
      const custom = HealthScoringConfig(cpu: MetricTiers(10, 20, 30, 1, 2, 3));
      await repo.insertSetting(HealthScoringViewModel.settingKey, custom.encode());

      final vm = await boot();
      expect(vm.saved, custom);
      expect(vm.draft[HealthMetric.cpu]!.warnAt, '10');
      vm.dispose();
    });

    test('a corrupt stored value falls back to the defaults rather than failing', () async {
      // A bad settings row must never stop the app scoring hosts.
      await repo.insertSetting(HealthScoringViewModel.settingKey, 'garbage;;;');
      final vm = await boot();
      expect(vm.saved, HealthScoringConfig.defaults);
      vm.dispose();
    });

    test('editing does not change the live rule until saved', () async {
      // Otherwise every host's score would shift under the user as they typed.
      final vm = await boot();
      vm.edit(HealthMetric.cpu, (f) => f.warnAt = '10');

      expect(vm.saved, HealthScoringConfig.defaults);
      expect(vm.isDirty, isTrue);
      expect(await repo.getSetting(HealthScoringViewModel.settingKey), isNull);
      vm.dispose();
    });

    test('saving persists and clears the dirty state', () async {
      final vm = await boot();
      vm.edit(HealthMetric.cpu, (f) => f.warnAt = '40');
      expect(await vm.save(), isNull);

      expect(vm.saved.cpu.warnAt, 40);
      expect(vm.isDirty, isFalse);
      expect(
        HealthScoringConfig.decode(
          await repo.getSetting(HealthScoringViewModel.settingKey),
        ).cpu.warnAt,
        40,
      );
      vm.dispose();
    });

    test('an invalid draft cannot be saved', () async {
      final vm = await boot();
      vm.edit(HealthMetric.cpu, (f) => f.warnAt = '99');

      expect(vm.validationError, contains('must increase'));
      expect(vm.canSave, isFalse);
      expect(await vm.save(), isNotNull);
      expect(await repo.getSetting(HealthScoringViewModel.settingKey), isNull);
      vm.dispose();
    });

    test('reverting throws the draft away', () async {
      final vm = await boot();
      vm.edit(HealthMetric.disk, (f) => f.criticalAt = '11');
      expect(vm.isDirty, isTrue);

      vm.revert();
      expect(vm.isDirty, isFalse);
      expect(vm.draft[HealthMetric.disk]!.criticalAt, '95');
      vm.dispose();
    });

    test('resetting restores and persists the defaults', () async {
      const custom = HealthScoringConfig(cpu: MetricTiers(10, 20, 30, 1, 2, 3));
      await repo.insertSetting(HealthScoringViewModel.settingKey, custom.encode());
      final vm = await boot();

      await vm.resetToDefaults();

      expect(vm.saved, HealthScoringConfig.defaults);
      expect(
        HealthScoringConfig.decode(await repo.getSetting(HealthScoringViewModel.settingKey)),
        HealthScoringConfig.defaults,
      );
      vm.dispose();
    });

    test('the preview shows what the draft would score', () async {
      // The numbers in this form are abstract until you see what they do.
      final vm = await boot();
      final before = vm.previewFor(
        cpuPercent: 60,
        memoryPercent: 10,
        diskPercent: 10,
        latencyMs: 5,
      );
      expect(before!.score, 95, reason: 'CPU 60 is over the default warn tier of 50');

      vm.edit(HealthMetric.cpu, (f) => f.warnPenalty = '20');
      final after = vm.previewFor(cpuPercent: 60, memoryPercent: 10, diskPercent: 10, latencyMs: 5);
      expect(after!.score, 80);
      expect(after.factors.single.label, contains('CPU 60%'));
      vm.dispose();
    });

    test('the preview is withheld while the draft is unusable', () async {
      // Showing a score derived from half-typed thresholds would be worse than showing none.
      final vm = await boot();
      vm.edit(HealthMetric.cpu, (f) => f.warnAt = '');
      expect(
        vm.previewFor(cpuPercent: 10, memoryPercent: 10, diskPercent: 10, latencyMs: 5),
        isNull,
      );
      vm.dispose();
    });
  });
}
