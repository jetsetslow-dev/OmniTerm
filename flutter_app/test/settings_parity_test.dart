import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/screens/tools/settings_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/theme/text_scaling.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:provider/provider.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late SettingsViewModel vm;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage({})));
    app = AppState(repo);
    vm = SettingsViewModel(app);
  });
  tearDown(() async {
    vm.dispose();
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {AppLockController? lock, TextScaler? scaler}) async {
    await app.start();
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: app),
          ChangeNotifierProvider.value(value: vm),
          if (lock != null) ChangeNotifierProvider<AppLockController>.value(value: lock),
          ChangeNotifierProvider(create: (_) => NavigationController()),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: scaler),
            child: child!,
          ),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Kotlin settings cards and controls appear in the reference order', (tester) async {
    await pump(tester);
    final labels = [
      'SECURITY GATE APP LOCK',
      'DISPLAY BEHAVIOR',
      'METRICS DATA PRUNING',
      'TERMINAL',
      'ALERT HISTORY',
      'SFTP TRANSFER WARNINGS',
    ];
    double previous = -1;
    for (final label in labels) {
      final found = find.text(label);
      expect(found, findsOneWidget);
      final y = tester.getTopLeft(found).dy;
      expect(y, greaterThan(previous));
      previous = y;
    }
    expect(find.byType(Slider), findsNWidgets(4));
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Reset all settings'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('settings.save'))).onPressed,
      isNull,
    );
  });

  testWidgets('System clears a forced theme and survives a fresh settings load', (tester) async {
    await repo.insertSetting('dark_mode', 'true');
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('settings.darkMode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System Default').last);
    await tester.pumpAndSettle();
    expect(vm.draft.darkMode, isNull);
    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await tester.pumpAndSettle();
    expect(await repo.getSetting('dark_mode'), '');
    final reopened = SettingsViewModel(app);
    await reopened.start();
    expect(reopened.saved.darkMode, isNull);
    reopened.dispose();
  });

  testWidgets('Settings popup uses platform text scaling independently of the app preset', (
    tester,
  ) async {
    await pump(tester, scaler: const OmniTextScaler(TextScaler.linear(1.3), 1.1));
    final menu = find.byKey(const ValueKey('settings.darkMode'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final item = tester.element(find.text('System Default').last);
    expect(MediaQuery.textScalerOf(item).scale(14), closeTo(14 * 1.3, .001));
  });

  testWidgets('Settings menu opens above its anchor when it cannot fit below', (tester) async {
    await pump(tester);
    tester.view.physicalSize = const Size(1200, 850);
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('settings.darkMode'));
    final list = find.descendant(
      of: find.byKey(const ValueKey('settings.list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(menu, 150, scrollable: list);
    await Scrollable.ensureVisible(tester.element(menu), alignment: 1);
    await tester.pumpAndSettle();
    final anchor = tester.getRect(menu);
    expect(anchor.bottom + 160, greaterThan(850 - 48));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final items = find.byWidgetPredicate((widget) => widget is PopupMenuItem<int>);
    expect(items, findsNWidgets(3));
    expect(tester.getBottomRight(items.last).dy, lessThanOrEqualTo(anchor.top));
  });

  test('highlight presets retain Kotlin character units, including Off', () {
    for (final value in [0, 256, 50000, 100000, 200000]) {
      final decoded = AppPreferences.decode({'editor_highlight_limit': '$value'});
      expect(decoded.encode()['editor_highlight_limit'], '$value');
    }
  });

  testWidgets('invalid SFTP edit cannot save and Cancel restores the displayed value', (
    tester,
  ) async {
    await pump(tester);
    final field = find.byKey(const ValueKey('settings.sftpWarnFileCount'));
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(vm.isDirty, isTrue);
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('settings.save'))).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('settings.revert')));
    await tester.pumpAndSettle();
    expect(vm.isDirty, isFalse);
    expect(tester.widget<TextField>(field).controller!.text, '50');
  });
  testWidgets('PIN setup opens immediately and saves only security configuration', (tester) async {
    final lock = AppLockController(repo);
    await lock.load();
    addTearDown(lock.dispose);
    await pump(tester, lock: lock);
    vm.update((p) => p.copyWith(keepScreenOn: true));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings.appLockEnabled')));
    await tester.pumpAndSettle();
    expect(find.text('Configure Security PIN'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings.pin.second')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('settings.pin.first')), '4913');
    await tester.tap(find.byKey(const ValueKey('settings.pin.confirm')));
    for (var i = 0; i < 100 && !lock.hasStoredPin; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(lock.hasStoredPin, isTrue);
    expect(await repo.getSetting('app_lock_enabled'), 'true');
    expect(vm.saved.appLockEnabled, isTrue);
    expect(vm.saved.keepScreenOn, isFalse);
    expect(vm.draft.keepScreenOn, isTrue);
    expect(vm.isDirty, isTrue);
  });

  testWidgets('SFTP numbers preserve typing and normalize only after Save', (tester) async {
    await pump(tester);
    final count = find.byKey(const ValueKey('settings.sftpWarnFileCount'));
    final size = find.byKey(const ValueKey('settings.sftpWarnGigabytes'));
    await tester.enterText(count, '99999');
    await tester.enterText(size, '0');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(count).controller!.text, '99999');
    expect(tester.widget<TextField>(size).controller!.text, '0');
    expect(vm.draft.sftpWarnFileCount, 10000);
    expect(vm.draft.sftpWarnGigabytes, 1);
    await tester.tap(find.byKey(const ValueKey('settings.save')));
    await tester.pumpAndSettle();
    expect(vm.saved.sftpWarnFileCount, 10000);
    expect(tester.widget<TextField>(count).controller!.text, '10000');
    expect(tester.widget<TextField>(size).controller!.text, '1');
    expect(vm.isDirty, isFalse);
  });

  test('failed settings persistence rolls back and keeps the draft available', () async {
    final failing = _FailingRepo(db);
    final state = AppState(failing);
    await state.start();
    final settings = SettingsViewModel(state);
    await settings.start();
    settings.update((p) => p.copyWith(darkMode: true));
    await expectLater(settings.save(), throwsStateError);
    expect(await repo.getSetting('dark_mode'), isNull);
    expect(settings.saved.darkMode, isNull);
    expect(settings.draft.darkMode, isTrue);
    expect(settings.isSaving, isFalse);
    settings.dispose();
    state.dispose();
  });

  test('concurrent saves share work and later edits remain unsaved', () async {
    final gated = _GatedRepo(db);
    final state = AppState(gated);
    await state.start();
    final settings = SettingsViewModel(state);
    await settings.start();
    settings.update((p) => p.copyWith(darkMode: true));
    final pending = settings.save();
    expect(settings.isSaving, isTrue);
    expect(identical(settings.save(), pending), isTrue);
    settings.update((p) => p.copyWith(darkMode: false));
    gated.ready.complete();
    await pending;
    expect(await repo.getSetting('dark_mode'), 'true');
    expect(settings.saved.darkMode, isTrue);
    expect(settings.draft.darkMode, isFalse);
    expect(settings.isDirty, isTrue);
    settings.dispose();
    state.dispose();
  });
}

class _FailingRepo extends AppRepository {
  _FailingRepo(AppDatabase db) : super(db, SecretStore(storage: FakeSecureStorage({})));
  @override
  Future<void> insertSetting(String key, String value) async {
    if (key == 'terminal_theme') throw StateError('fixture write failed');
    await super.insertSetting(key, value);
  }
}

class _GatedRepo extends AppRepository {
  _GatedRepo(AppDatabase db) : super(db, SecretStore(storage: FakeSecureStorage({})));
  final ready = Completer<void>();
  @override
  Future<void> insertSetting(String key, String value) async {
    await ready.future;
    await super.insertSetting(key, value);
  }
}
