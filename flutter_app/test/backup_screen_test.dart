import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/backup_selection.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/backup_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late BackupViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server({required String name}) => Server(
        id: 0,
        name: name,
        host: '10.0.0.1',
        port: 22,
        username: 'root',
        serverColor: 'Default',
        authType: 'password',
        authPassword: 'hunter2',
        sudoPassword: '',
        notes: '',
        keepAlive: 30,
        sshCompression: false,
        persistentSession: false,
        proxyCommand: '',
        proxyType: 'none',
        proxyHost: '',
        proxyPort: 0,
        proxyUser: '',
        proxyPassword: '',
        agentForwarding: false,
        healthScore: 100,
        lastLatency: 0,
        status: 'offline',
        authStatus: 'unknown',
      );

  Future<void> pump(WidgetTester tester) async {
    // The screen is a long scrolling form; the default 800x600 surface leaves the lower half
    // unlaid-out, so finders below the fold see nothing.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await app.start();
    vm = BackupViewModel(app);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<BackupViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: BackupScreen()),
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

  testWidgets('every section is offered, all selected by default', (tester) async {
    await pump(tester);

    for (final section in BackupSection.values) {
      expect(find.byKey(ValueKey('backup.section.${section.name}')), findsOneWidget);
    }
    expect(vm.selection.sections, BackupSection.values.toSet());
    await finish(tester);
  });

  testWidgets('a coupled section says what it drags in', (tester) async {
    // Explained before the checkbox moves on its own, which would otherwise look like the app
    // second-guessing the user.
    await pump(tester);
    expect(find.textContaining('Includes hosts'), findsWidgets);
    await finish(tester);
  });

  testWidgets('unticking hosts unticks everything that needs them', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.section.servers')));
    await tester.pumpAndSettle();

    expect(vm.selection.contains(BackupSection.servers), isFalse);
    expect(vm.selection.contains(BackupSection.alertRules), isFalse);
    expect(vm.selection.contains(BackupSection.portForwards), isFalse);
    expect(vm.selection.contains(BackupSection.sshKeys), isTrue,
        reason: 'keys do not depend on hosts');
    await finish(tester);
  });

  testWidgets('ticking alert rules re-ticks hosts', (tester) async {
    await pump(tester);
    vm.selectNone();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('backup.section.alertRules')));
    await tester.pumpAndSettle();

    expect(vm.selection.contains(BackupSection.servers), isTrue);
    await finish(tester);
  });

  testWidgets('select all and none work', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
    await tester.pumpAndSettle();
    expect(vm.selection.isEmpty, isTrue);

    await tester.tap(find.byKey(const ValueKey('backup.selectAll')));
    await tester.pumpAndSettle();
    expect(vm.selection.sections, BackupSection.values.toSet());
    await finish(tester);
  });

  testWidgets('a sensitive selection explains why a passphrase is needed', (tester) async {
    // A prompt with no explanation reads as an obstacle; this one protects stored passwords.
    await pump(tester);
    expect(find.byKey(const ValueKey('backup.sensitiveNote')), findsOneWidget);
    expect(find.textContaining('no way to recover'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a settings-only backup needs no passphrase', (tester) async {
    await pump(tester);
    vm
      ..selectNone()
      ..toggleSection(BackupSection.settings, enabled: true);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup.sensitiveNote')), findsNothing);
    await finish(tester);
  });

  testWidgets('export is disabled with nothing selected', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('backup.export')));
    expect(button.onPressed, isNull);
    await finish(tester);
  });

  testWidgets('exporting asks for a passphrase and warns it cannot be reset', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    vm
      ..selectNone()
      ..toggleSection(BackupSection.settings, enabled: true)
      ..toggleSection(BackupSection.sshKeys, enabled: true);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('backup.export')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup.passphrase.dialog')), findsOneWidget);
    expect(find.textContaining('Nobody can reset it'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup.passphrase.cancel')));
    await tester.pumpAndSettle();
    expect(vm.status, isNull, reason: 'cancelling must not produce a file');
    await finish(tester);
  });

  testWidgets('the restore section states that nothing is deleted', (tester) async {
    // The two things a user needs before tapping: nothing is destroyed, and the passphrase is not
    // recoverable.
    await pump(tester);
    expect(find.textContaining('nothing is deleted or overwritten'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('restoring pasted plain JSON works without a passphrase prompt', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('backup.text.field')),
      '{"v":2,"wolTargets":[{"name":"nas","macAddress":"aa:bb:cc:dd:ee:ff"}]}',
    );
    await tester.tap(find.byKey(const ValueKey('backup.text.confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup.passphrase.dialog')), findsNothing);
    expect((await repo.getAllWolTargets()).single.name, 'nas');
    expect(find.textContaining('Restored'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a bad restore is reported, not silently ignored', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('backup.text.field')), 'not a backup at all');
    await tester.tap(find.byKey(const ValueKey('backup.text.confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup.message')), findsOneWidget);
    expect(vm.error, isNotNull);
    await finish(tester);
  });
}
