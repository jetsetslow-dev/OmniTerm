import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/backup_selection.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';
import 'package:omniterm/ui/screens/tools/backup_screen.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

class _ControlledSettings extends AppRepository {
  _ControlledSettings(AppDatabase db)
    : super(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));

  Completer<void>? firstWriteGate;
  final firstWriteStarted = Completer<void>();
  final firstWriteFinished = Completer<void>();
  final secondWriteFinished = Completer<void>();
  Completer<String?>? selectionRead;
  Completer<String?>? timeRead;
  bool failTimeRead = false;
  bool failSelectionWrite = false;
  int writes = 0;

  @override
  Future<void> insertSetting(String key, String value) async {
    if (key != 'backup_export_selection') return super.insertSetting(key, value);
    final index = ++writes;
    if (index == 1) {
      firstWriteStarted.complete();
      await firstWriteGate?.future;
    }
    try {
      if (failSelectionWrite) throw StateError('fixture settings unavailable');
      await super.insertSetting(key, value);
    } finally {
      if (index == 1) firstWriteFinished.complete();
      if (index == 2) secondWriteFinished.complete();
    }
  }

  @override
  Future<String?> getSetting(String key) async {
    if (key == 'backup_last_export_time' && failTimeRead) {
      throw StateError('fixture time unavailable');
    }
    if (key == 'backup_last_export_time' && timeRead != null) return timeRead!.future;
    if (key == 'backup_export_selection' && selectionRead != null) {
      return selectionRead!.future;
    }
    return super.getSetting(key);
  }
}

void main() {
  late AppDatabase db;
  late _ControlledSettings repo;
  late AppState app;
  late BackupViewModel model;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = _ControlledSettings(db);
    app = AppState(repo);
    model = BackupViewModel(app);
  });

  tearDown(() async {
    model.dispose();
    app.dispose();
    await db.close();
  });

  test('queued choices cannot leave the older selection in storage', () async {
    final gate = repo.firstWriteGate = Completer<void>();
    model.selectNone();
    await repo.firstWriteStarted.future;
    model.selectAll();
    // A later write must wait for the first, including its asynchronous completion.
    await Future<void>.delayed(Duration.zero);
    final writesBeforeRelease = repo.writes;
    gate.complete();
    await repo.firstWriteFinished.future;
    await repo.secondWriteFinished.future;
    expect(writesBeforeRelease, 1, reason: 'pending writes must be serialized');
    expect(
      BackupSelection.decode(await repo.getSetting('backup_export_selection')).sections,
      model.selection.sections,
      reason: 'the newest visible choice must also survive reopening the app',
    );
  });

  test('a pending initial read cannot replace a newer user choice', () async {
    final read = repo.selectionRead = Completer<String?>();
    final loading = model.loadSelection();
    model.selectNone();
    await repo.firstWriteFinished.future;
    read.complete(BackupSelection.all().encode());
    await loading;
    expect(model.selection.isEmpty, isTrue);
  });

  test('an unavailable backup time is handled by the model', () async {
    repo.failTimeRead = true;
    await expectLater(model.loadLastExportTime(), completes);
    expect(model.lastExportTime, isNull);
    expect(model.lastExportTimeError, contains('could not be read'));
    repo.failTimeRead = false;
    await repo.insertSetting('backup_last_export_time', '1700000000000');
    await model.loadLastExportTime();
    expect(model.lastExportTime!.millisecondsSinceEpoch, 1700000000000);
    expect(model.lastExportTimeError, isNull);
  });

  test('a failed choice stays active and can be remembered by retrying', () async {
    repo.failSelectionWrite = true;
    model.selectNone();
    await repo.firstWriteFinished.future;
    await Future<void>.delayed(Duration.zero);
    expect(model.selection.isEmpty, isTrue);
    expect(model.selectionSaving, isFalse);
    expect(model.selectionSaveError, contains('could not be remembered'));
    expect(await repo.getSetting('backup_export_selection'), isNull);
    repo.failSelectionWrite = false;
    model.retrySelectionSave();
    await repo.secondWriteFinished.future;
    await Future<void>.delayed(Duration.zero);
    expect(model.selectionSaveError, isNull);
    expect(model.selectionSaving, isFalse);
    expect(
      BackupSelection.decode(await repo.getSetting('backup_export_selection')).isEmpty,
      isTrue,
    );
  });

  test('a delayed time read cannot replace a backup written while it was pending', () async {
    final read = repo.timeRead = Completer<String?>();
    final loading = model.loadLastExportTime();
    model.reportSaved('fixture backup', encrypted: false);
    final written = model.lastExportTime;
    read.complete('1700000000000');
    await loading;
    expect(model.lastExportTime, written);
    expect(model.lastExportTimeLoading, isFalse);
    // Drain the metadata write before closing the fixture database.
    await repo.getSetting('backup_export_selection');
  });

  Future<void> openScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<BackupViewModel>.value(value: model),
        ],
        child: const MaterialApp(home: Scaffold(body: BackupScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    await tester.pump();
    expect(
      done(),
      isTrue,
      reason: 'the fixture operation must finish within its original deadline',
    );
  }

  testWidgets('selection progress, storage failure and retry are visible', (tester) async {
    await openScreen(tester);
    final gate = repo.firstWriteGate = Completer<void>();
    repo.failSelectionWrite = true;
    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    final setting = find.byKey(const ValueKey('backup.section.settings'));
    await tester.scrollUntilVisible(
      setting,
      160,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('backup.list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await Scrollable.ensureVisible(tester.element(setting), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(setting);
    await tester.pump();
    try {
      expect(
        model.selectionSaving,
        isTrue,
        reason: 'the visible checkbox must actually be changed',
      );
      expect(
        find.byType(CircularProgressIndicator).hitTestable(),
        findsWidgets,
        reason: 'the pending choice must show progress beside the visible checkbox',
      );
    } finally {
      gate.complete();
      await pumpUntil(tester, () => !model.selectionSaving);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup.selection.error')).hitTestable(), findsOneWidget);
    repo.failSelectionWrite = false;
    await tester.tap(find.byKey(const ValueKey('backup.selection.retry')));
    await pumpUntil(tester, () => !model.selectionSaving);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup.selection.error')), findsNothing);
    expect(model.selection.contains(BackupSection.settings), isFalse);
    expect(
      BackupSelection.decode(
        await tester.runAsync<String?>(() => repo.getSetting('backup_export_selection')),
      ).contains(BackupSection.settings),
      isFalse,
    );
  });

  testWidgets('an unreadable timestamp shows Unknown and a working retry', (tester) async {
    repo.failTimeRead = true;
    await openScreen(tester);
    await pumpUntil(tester, () => !model.lastExportTimeLoading);
    expect(find.text('Last backup: Unknown'), findsOneWidget);
    expect(find.text('Last backup: Never'), findsNothing);
    repo.failTimeRead = false;
    await tester.runAsync(() => repo.insertSetting('backup_last_export_time', '1700000000000'));
    await tester.tap(find.byKey(const ValueKey('backup.lastExport.retry')));
    await pumpUntil(tester, () => !model.lastExportTimeLoading);
    expect(model.lastExportTime!.millisecondsSinceEpoch, 1700000000000);
    expect(find.byKey(const ValueKey('backup.lastExport.retry')), findsNothing);
  });
}
