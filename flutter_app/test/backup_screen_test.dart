import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/secure_host_key_store.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/backup_selection.dart';
import 'package:omniterm/platform/backup_file_store.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/backup_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_backup_file_store.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late BackupViewModel vm;
  late FakeBackupFileStore files;

  setUp(() {
    files = FakeBackupFileStore();
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
    vm = BackupViewModel(
      app,
      // Injected: the default reaches for real secure storage, which a widget test has no channel
      // for, and an export that silently lost its pins would still look like a pass.
      hostKeyTrust: SshHostKeyTrust(
        SecureHostKeyStore(storage: FakeSecureStorage(<String, String>{})),
      ),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<BackupViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: Scaffold(body: BackupScreen(fileStore: files)),
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

  Future<void> confirmRestore(WidgetTester tester) async {
    expect(find.byKey(const ValueKey('backup.restore.selectionDialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup.restore.continue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup.restore.confirmDialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup.restore.confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('every section is offered, with crash logs opt-in', (tester) async {
    await pump(tester);

    for (final section in BackupSection.values) {
      expect(find.byKey(ValueKey('backup.section.${section.name}')), findsOneWidget);
    }
    expect(vm.selection.sections, BackupSection.values.toSet()..remove(BackupSection.crashLogs));
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
    expect(
      vm.selection.contains(BackupSection.sshKeys),
      isTrue,
      reason: 'keys do not depend on hosts',
    );
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

  testWidgets('a passphrase the export would refuse cannot leave the dialog', (tester) async {
    // The defect this covers, reported from the field: the dialog advertised eight characters and
    // enabled its button at eight, the picker then created the file, and only afterwards did the
    // export refuse anything under twelve — leaving a 0-byte "backup" on disk and an error. Kotlin
    // had the same three numbers in two values (`ui/ToolsScreen.kt:2808` said 8,
    // `ui/AppViewModel.kt:11360` demanded 12); this port had no minimum at all.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    vm
      ..selectNone()
      ..toggleSection(BackupSection.settings, enabled: true)
      ..toggleSection(BackupSection.sshKeys, enabled: true);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('backup.export')));
    await tester.pumpAndSettle();

    // The number is on the field while the user types, not in an error after the file exists.
    expect(
      find.textContaining('At least ${BackupViewModel.passphraseMinLength} characters'),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(const ValueKey('backup.passphrase.field')), 'short11chr');
    await tester.pumpAndSettle();
    final tooShort = tester.widget<TextButton>(
      find.byKey(const ValueKey('backup.passphrase.confirm')),
    );
    expect(
      tooShort.onPressed,
      isNull,
      reason: 'a dialog must not hand back a value its caller will reject',
    );

    await tester.enterText(
      find.byKey(const ValueKey('backup.passphrase.field')),
      'a-long-enough-passphrase',
    );
    await tester.pumpAndSettle();
    final longEnough = tester.widget<TextButton>(
      find.byKey(const ValueKey('backup.passphrase.confirm')),
    );
    expect(longEnough.onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('backup.passphrase.cancel')));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('the export refuses a short passphrase even if a caller asks it to', (tester) async {
    // The dialog is one caller. The boundary that decides whether credentials are weakly encrypted
    // has to hold on its own, or the next screen to call it inherits the old defect.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    vm
      ..selectNone()
      ..toggleSection(BackupSection.sshKeys, enabled: true);
    await tester.pumpAndSettle();

    expect(await vm.exportBackup('short'), isNull);
    expect(vm.error, contains('at least ${BackupViewModel.passphraseMinLength} characters'));
    await finish(tester);
  });

  testWidgets('the restore section states that nothing is deleted', (tester) async {
    // The two things a user needs before tapping: nothing is destroyed, and the passphrase is not
    // recoverable.
    await pump(tester);
    expect(find.textContaining('nothing is deleted or overwritten'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('restoring a plain JSON file works without a passphrase prompt', (tester) async {
    files.openContents = '{"v":2,"wolTargets":[{"name":"nas","macAddress":"aa:bb:cc:dd:ee:ff"}]}';
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();

    expect(files.openCalls, 1);
    expect(find.byKey(const ValueKey('backup.passphrase.dialog')), findsNothing);
    await confirmRestore(tester);
    expect((await repo.getAllWolTargets()).single.name, 'nas');
    expect(find.textContaining('Restored'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('restore previews sections and can exclude one', (tester) async {
    files.openContents =
        '{"v":2,"wolTargets":[{"name":"nas","macAddress":"aa:bb:cc:dd:ee:ff"}],'
        '"settings":[{"key":"theme","value":"light"}]}';
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();

    expect(find.text('1 item(s)'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('backup.restore.section.settings')));
    await tester.pumpAndSettle();
    await confirmRestore(tester);

    expect((await repo.getAllWolTargets()).single.name, 'nas');
    expect(await repo.getSetting('theme'), isNull);
    await finish(tester);
  });

  testWidgets('restore can choose individual hosts', (tester) async {
    files.openContents =
        '{"v":2,"servers":['
        '{"id":10,"name":"nas","host":"10.0.0.10"},'
        '{"id":11,"name":"pi","host":"10.0.0.11"}]}';
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();
    expect(find.text('Hosts to restore'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup.restore.host.11')));
    await tester.pumpAndSettle();
    await confirmRestore(tester);

    expect((await repo.getAllServers()).map((host) => host.name), ['nas']);
    await finish(tester);
  });

  testWidgets('a bad restore is reported, not silently ignored', (tester) async {
    files.openContents = 'not a backup at all';
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup.message')), findsOneWidget);
    expect(vm.error, isNotNull);
    await finish(tester);
  });

  group('saving to a file', () {
    testWidgets('the backup text is what gets written', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.section.wolTargets')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup.export')));
      await tester.pumpAndSettle();

      expect(files.saved, hasLength(1));
      expect(files.saved.single.fileName, endsWith('.omnibak'));
      expect(files.saved.single.contents, contains('wolTargets'));
      await finish(tester);
    });

    testWidgets('a save names where the file went', (tester) async {
      // A backup the user cannot find is one they will assume did not happen.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.section.wolTargets')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup.export')));
      await tester.pumpAndSettle();

      expect(find.textContaining('/storage/Download/backup'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an unencrypted backup says so plainly', (tester) async {
      // Nothing sensitive was selected, so there is no passphrase — and the file is readable by
      // anyone who opens it. That is worth saying at the moment it becomes a portable file.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.section.wolTargets')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup.export')));
      await tester.pumpAndSettle();

      expect(find.textContaining('not encrypted'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('cancelling the picker says nothing at all', (tester) async {
      // The user cancelled; announcing it is noise, and nothing was written anywhere.
      files.saveResult = const BackupSaveResult(BackupSaveOutcome.cancelled);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.section.wolTargets')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup.export')));
      await tester.pumpAndSettle();

      expect(vm.error, isNull);
      expect(vm.status, isNull);
      await finish(tester);
    });

    testWidgets('a failed save is reported rather than looking successful', (tester) async {
      files.saveResult = const BackupSaveResult(
        BackupSaveOutcome.failed,
        error: 'permission denied',
      );
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('backup.selectNone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup.section.wolTargets')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('backup.export')));
      await tester.pumpAndSettle();

      expect(find.textContaining('permission denied'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an unreadable file is named as such, not as a bad backup', (tester) async {
      files.openError = const BackupReadException('That file is not a text backup.');
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('backup.import')));
      await tester.pumpAndSettle();

      expect(find.textContaining('not a text backup'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('cancelling the open picker does nothing', (tester) async {
      files.openContents = null;
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('backup.import')));
      await tester.pumpAndSettle();

      expect(vm.error, isNull);
      await finish(tester);
    });
  });

  /// "Last backup", ported from Kotlin's `lastBackupExportTime` (`AppViewModel.kt:1052`, shown at
  /// `ToolsScreen.kt:2691`).
  ///
  /// Flutter recorded nothing, so the screen could not tell a user who had never taken a backup from
  /// one who took a backup a year ago — which is the question this screen exists to answer.
  group('last backup time', () {
    Text lastExport(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('backup.lastExport')));

    testWidgets('a device that has never exported says so plainly', (tester) async {
      await pump(tester);

      expect(lastExport(tester).data, 'Last backup: Never');
      await finish(tester);
    });

    testWidgets('a stored time is shown when the screen opens', (tester) async {
      final when = DateTime(2026, 3, 4, 15, 30);
      await repo.insertSetting('backup_last_export_time', '${when.millisecondsSinceEpoch}');
      await pump(tester);

      final shown = lastExport(tester).data!;
      expect(shown, isNot(contains('Never')));
      expect(shown, contains('2026'));
      await finish(tester);
    });

    testWidgets('a completed save records the time under the Kotlin key', (tester) async {
      await pump(tester);

      vm.reportSaved('/tmp/backup.omnibak', encrypted: true);
      await tester.pumpAndSettle();

      expect(lastExport(tester).data, isNot(contains('Never')));
      final stored = int.tryParse(await repo.getSetting('backup_last_export_time') ?? '');
      expect(stored, isNotNull);
      expect(
        stored,
        vm.lastExportTime!.millisecondsSinceEpoch,
        reason: 'what is shown must be what was stored',
      );
      await finish(tester);
    });

    testWidgets('a zero stored value reads as never, not as 1970', (tester) async {
      // Kotlin writes 0 for "never" and renders it as "Never"; a 1970 date would be a lie, and a
      // confident-looking one.
      await repo.insertSetting('backup_last_export_time', '0');
      await pump(tester);

      expect(lastExport(tester).data, 'Last backup: Never');
      await finish(tester);
    });

    testWidgets('a malformed stored value reads as never', (tester) async {
      await repo.insertSetting('backup_last_export_time', 'whenever');
      await pump(tester);

      expect(lastExport(tester).data, 'Last backup: Never');
      await finish(tester);
    });
  });

  /// Remembering what to include, ported from `updateBackupExportSelection`
  /// (`AppViewModel.kt:2310`).
  ///
  /// Flutter reset to "everything" on every visit, so a user who deliberately excludes crash logs or
  /// alert history had to exclude them again every single time.
  group('remembered selection', () {
    testWidgets('changing the selection writes it under the Kotlin key', (tester) async {
      await pump(tester);

      vm.selectNone();
      await tester.pumpAndSettle();

      expect(await repo.getSetting('backup_export_selection'), 'v2:');
      await finish(tester);
    });

    testWidgets('a stored selection is restored when the screen opens', (tester) async {
      await repo.insertSetting('backup_export_selection', 'v2:scripts');
      await pump(tester);

      expect(vm.selection.contains(BackupSection.scripts), isTrue);
      expect(
        vm.selection.contains(BackupSection.servers),
        isFalse,
        reason: 'the stored choice must win over the default of everything',
      );
      await finish(tester);
    });

    testWidgets('an Android-written v1 selection is honoured', (tester) async {
      await repo.insertSetting('backup_export_selection', 'servers,sshKeys');
      await pump(tester);

      expect(vm.selection.contains(BackupSection.servers), isTrue);
      expect(vm.selection.contains(BackupSection.portForwards), isTrue);
      await finish(tester);
    });

    testWidgets('nothing stored leaves the default alone', (tester) async {
      await pump(tester);

      expect(vm.selection.contains(BackupSection.servers), isTrue);
      await finish(tester);
    });
  });
}
