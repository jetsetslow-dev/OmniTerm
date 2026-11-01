import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/secure_host_key_store.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/backup/android_json.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/backup_selection.dart';
import 'package:omniterm/platform/backup_file_store.dart';
import 'package:omniterm/platform/long_operation_notifications.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/backup_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_backup_file_store.dart';
import 'support/fake_secure_storage.dart';

/// Records the order in which system surfaces were asked for.
///
/// The defect this exists for is invisible to a finder: both the permission dialog and the file
/// picker are other apps' windows, so the only thing a test can observe is the sequence of calls
/// the app made.
class _SystemSurfaceLog {
  final List<String> order = [];
  Completer<void>? permissionGate;

  Future<bool> requestPermission() async {
    order.add('permission');
    final gate = permissionGate;
    if (gate != null) await gate.future;
    return true;
  }

  void notePicker() => order.add('picker');
}

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

  /// Kotlin's Backup button opens the "Backup sections" dialog.
  Future<void> openSections(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('backup.export')));
    await tester.pumpAndSettle();
  }

  /// Selection now lives in Kotlin's dialog; tests set it on the app-scoped model directly.
  Future<void> selectOnly(WidgetTester tester, BackupSection section) async {
    vm
      ..selectNone()
      ..toggleSection(section, enabled: true);
    await tester.pumpAndSettle();
  }

  /// Backup → Continue → "Encrypt Backup" passphrase → Choose location. Every export is encrypted,
  /// as Kotlin requires. Leaves the final pump to the caller.
  Future<void> tapExportWithPassphrase(WidgetTester tester) async {
    await openSections(tester);
    await tester.tap(find.byKey(const ValueKey('backup.sections.continue')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('backup.passphrase.field')),
      'a-long-enough-passphrase',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup.passphrase.confirm')));
  }

  Future<void> pump(WidgetTester tester, {LongOperationNotifications? notifications}) async {
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
      operationNotifications: notifications,
      // Kotlin encrypts every export. The real export runs on a worker isolate, which cannot
      // finish on the widget clock, so the screen flow gets an envelope-shaped stand-in; the
      // cipher has its own tests.
      encrypt: (json, passphrase) async => encodeAndroidJson({
        'v': 2,
        'salt': 'test',
        'iv': 'test',
        'data': base64.encode(utf8.encode(json)),
      }),
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
    expect(find.byKey(const ValueKey('backup.restore.confirmDialog.dialog')), findsOneWidget);
    expect(find.text('Restore selected data?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup.restore.confirmDialog.confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('every section is offered in Kotlin\'s dialog, with crash logs opt-in', (
    tester,
  ) async {
    await pump(tester);
    await openSections(tester);

    expect(find.text('Backup sections'), findsOneWidget);
    expect(find.text('Choose what to include'), findsOneWidget);
    for (final section in BackupSection.values) {
      expect(find.byKey(ValueKey('backup.section.${section.name}')), findsOneWidget);
      expect(find.text(backupSectionLabels[section]!), findsOneWidget);
    }
    expect(vm.selection.sections, BackupSection.values.toSet()..remove(BackupSection.crashLogs));
    await finish(tester);
  });

  testWidgets('the legend explains sensitive sections and coupled sections', (tester) async {
    await pump(tester);
    await openSections(tester);
    expect(find.text('* Sensitive — selecting forces an encrypted backup.'), findsOneWidget);
    expect(find.textContaining('Alert rules and history include Servers.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('unticking hosts unticks everything that needs them', (tester) async {
    await pump(tester);
    await openSections(tester);

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
    await openSections(tester);

    await tester.tap(find.byKey(const ValueKey('backup.section.alertRules')));
    await tester.pumpAndSettle();

    expect(vm.selection.contains(BackupSection.servers), isTrue);
    await finish(tester);
  });

  testWidgets('Continue is disabled with nothing selected', (tester) async {
    await pump(tester);
    vm.selectNone();
    await tester.pumpAndSettle();
    await openSections(tester);

    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('backup.sections.continue')),
    );
    expect(button.onPressed, isNull);
    await finish(tester);
  });

  testWidgets('a sensitive selection explains that the backup will be encrypted', (tester) async {
    await pump(tester);
    await openSections(tester);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('backup.sensitiveNote'))).data,
      'Sensitive sections selected: backup will be encrypted.',
    );
    await finish(tester);
  });

  testWidgets('a settings-only backup still needs a passphrase, as in Kotlin', (tester) async {
    await pump(tester);
    await selectOnly(tester, BackupSection.settings);
    await openSections(tester);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('backup.sensitiveNote'))).data,
      'Sensitive sections selected: backup will be encrypted.',
    );
    await tester.tap(find.byKey(const ValueKey('backup.sections.continue')));
    await tester.pumpAndSettle();
    expect(find.text('Encrypt Backup'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a save that finishes after the screen closes is still recorded', (tester) async {
    // Saving hands off to the system file picker, another app's window. The Backup screen is
    // routinely unmounted behind it, and since the Flutter engine is retained the view model
    // outlives the screen. Gating the outcome on `context.mounted` threw away a backup that had
    // really been written: no confirmation and no last-export time, so coming back to the screen
    // showed no trace of it.
    final gate = Completer<void>();
    files.saveGate = gate;
    await pump(tester);
    await selectOnly(tester, BackupSection.wolTargets);

    await tapExportWithPassphrase(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      gate.isCompleted,
      isFalse,
      reason: 'the picker must still be open for this to be a test',
    );

    // The user leaves the screen while the picker is up.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // ...and only then chooses a location.
    gate.complete();
    await tester.pumpAndSettle();

    expect(files.saved, hasLength(1), reason: 'the file really was written');
    expect(
      vm.statusIsSuccess,
      isTrue,
      reason: 'a backup that was written must read as written, even if nobody was watching',
    );
    expect(vm.lastExportTime, isNotNull, reason: 'and must stamp the last-export time');
    await finish(tester);
  });

  testWidgets('cancelling the sections dialog writes nothing and says so', (tester) async {
    await pump(tester);
    await openSections(tester);
    await tester.tap(find.byKey(const ValueKey('backup.sections.cancel')));
    await tester.pumpAndSettle();

    expect(files.saved, isEmpty);
    expect(vm.status, 'Backup cancelled. Nothing was written.');
    await finish(tester);
  });

  testWidgets('exporting asks for a passphrase in Kotlin\'s Encrypt Backup dialog', (tester) async {
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await openSections(tester);
    await tester.tap(find.byKey(const ValueKey('backup.sections.continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup.passphrase.dialog')), findsOneWidget);
    expect(find.text('Encrypt Backup'), findsOneWidget);
    expect(find.textContaining("Choose a passphrase you'll need for restore"), findsOneWidget);
    expect(find.text('Choose location'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup.passphrase.cancel')));
    await tester.pumpAndSettle();
    expect(files.saved, isEmpty, reason: 'cancelling must not produce a file');
    expect(vm.status, 'Backup cancelled. Nothing was written.');
    expect(vm.statusIsSuccess, isFalse, reason: 'and must not read as a completed backup');
    await finish(tester);
  });

  testWidgets('a passphrase the export would refuse cannot leave the dialog', (tester) async {
    // The dialog states the minimum and keeps its button disabled below it, so it never hands back
    // a passphrase the export would refuse after a file already existed.
    await repo.insertServer(server(name: 'nas'));
    await pump(tester);
    await openSections(tester);
    await tester.tap(find.byKey(const ValueKey('backup.sections.continue')));
    await tester.pumpAndSettle();

    expect(
      find.text('Passphrase (min ${BackupViewModel.passphraseMinLength} chars)'),
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

  testWidgets('the card explains Backup and Restore in Kotlin\'s words', (tester) async {
    await pump(tester);
    expect(find.text('OmniTerm app backup'), findsOneWidget);
    expect(find.textContaining('It does NOT back up any files or data'), findsOneWidget);
    expect(
      find.textContaining('Restore shows available sections after the selected file is read.'),
      findsOneWidget,
    );
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

  testWidgets('restore previews sections with counts and can exclude one', (tester) async {
    files.openContents =
        '{"v":2,"wolTargets":[{"name":"nas","macAddress":"aa:bb:cc:dd:ee:ff"}],'
        '"settings":[{"key":"theme","value":"light"}]}';
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('backup.import')));
    await tester.pumpAndSettle();

    expect(find.text('Wake on LAN * (1)'), findsOneWidget);
    expect(find.text('Settings & customizations * (1)'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('backup.restore.section.settings')));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(find.byKey(const ValueKey('backup.restore.host.11')));
    await tester.pumpAndSettle();
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
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();

      expect(files.saved, hasLength(1));
      expect(files.saved.single.fileName, matches(RegExp(r'^omniterm_backup_\d{10}\.json$')));
      expect(BackupViewModel.looksEncrypted(files.saved.single.contents), isTrue);
      await finish(tester);
    });

    testWidgets('a save reports Kotlin\'s written summary', (tester) async {
      await pump(tester);
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();

      expect(
        vm.status,
        'Encrypted backup written: 0 servers, 0 keys, 0 profiles, 0 scripts, 0 rules, '
        '0 alert history, 0 WoL, 0 shares, 0 tunnels, 0 settings.',
      );
      await finish(tester);
    });

    testWidgets('a wake-target-only backup is still encrypted, as in Kotlin', (tester) async {
      await pump(tester);
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();

      expect(BackupViewModel.looksEncrypted(files.saved.single.contents), isTrue);
      expect(find.textContaining('not encrypted'), findsNothing);
      await finish(tester);
    });

    testWidgets('the picker waits for the permission answer, not just the request', (tester) async {
      // Ordering alone cannot see this defect: `unawaited(request())` still *initiates* the call
      // before the picker, so a test that records call order passes either way. What distinguishes
      // them is whether the picker opens while the permission dialog is still on screen — so the
      // permission is held open and the picker must not have happened yet.
      final surfaces = _SystemSurfaceLog()..permissionGate = Completer<void>();
      files.onSave = surfaces.notePicker;
      await pump(
        tester,
        notifications: LongOperationNotifications(
          channel: const MethodChannel('omniterm/long_operations.test'),
          requestNotificationPermission: surfaces.requestPermission,
        ),
      );
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
      // Preparation remains visibly busy until the held platform callback completes.
      await tester.pump();

      expect(surfaces.order, ['permission'], reason: 'the dialog is up and still unanswered');
      expect(
        files.saved,
        isEmpty,
        reason: 'opening the picker over a live permission dialog is the defect',
      );

      surfaces.permissionGate!.complete();
      await tester.pumpAndSettle();

      expect(surfaces.order, ['permission', 'picker']);
      expect(files.saved, hasLength(1), reason: 'and the export still finishes afterwards');
      await finish(tester);
    });

    testWidgets('export keeps the sections chosen before waiting for permission', (tester) async {
      final surfaces = _SystemSurfaceLog()..permissionGate = Completer<void>();
      await pump(
        tester,
        notifications: LongOperationNotifications(
          channel: const MethodChannel('omniterm/long_operations.test'),
          requestNotificationPermission: surfaces.requestPermission,
        ),
      );
      vm.selectNone();
      vm.toggleSection(BackupSection.settings, enabled: true);
      await tester.pumpAndSettle();
      await tapExportWithPassphrase(tester);
      await tester.pump();
      expect(surfaces.order, ['permission']);

      // An app-scoped draft can change while a platform callback is outstanding. The running
      // export must keep the settings-only choice that was checked before asking permission.
      vm.selectAll();
      surfaces.permissionGate!.complete();
      await tester.pumpAndSettle();

      expect(files.saved, hasLength(1));
      // Every Kotlin-format section is present; only the chosen one carries rows.
      final envelope = jsonDecode(files.saved.single.contents) as Map<String, dynamic>;
      final document =
          jsonDecode(utf8.decode(base64.decode(envelope['data'] as String)))
              as Map<String, dynamic>;
      expect(document['settings'], isNotEmpty);
      expect(document['servers'], isEmpty);
      expect(vm.error, isNull);
      expect(vm.selection.contains(BackupSection.servers), isTrue);
      await finish(tester);
    });

    testWidgets('permission preparation shows progress and prevents duplicate export', (
      tester,
    ) async {
      final surfaces = _SystemSurfaceLog()..permissionGate = Completer<void>();
      await pump(
        tester,
        notifications: LongOperationNotifications(
          channel: const MethodChannel('omniterm/long_operations.test'),
          requestNotificationPermission: surfaces.requestPermission,
        ),
      );
      await selectOnly(tester, BackupSection.settings);
      await tapExportWithPassphrase(tester);
      await tester.pump();
      try {
        expect(find.text('Exporting…'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byKey(const ValueKey('backup.export'))).onPressed,
          isNull,
        );
        expect(files.saved, isEmpty);
      } finally {
        surfaces.permissionGate!.complete();
        await tester.pumpAndSettle();
      }
      expect(files.saved, hasLength(1));
      await finish(tester);
    });

    testWidgets('a denied or slow permission never blocks the export', (tester) async {
      // Asking is a courtesy. The work the user started must still happen.
      final surfaces = _SystemSurfaceLog();
      files.onSave = surfaces.notePicker;
      await pump(
        tester,
        notifications: LongOperationNotifications(
          channel: const MethodChannel('omniterm/long_operations.test'),
          requestNotificationPermission: () async {
            surfaces.order.add('permission');
            throw PlatformException(code: 'denied');
          },
        ),
      );
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();

      expect(surfaces.order, ['permission', 'picker']);
      expect(files.saved, hasLength(1), reason: 'the backup was still written');
      await finish(tester);
    });

    testWidgets('cancelling the picker says so, without calling it an error', (tester) async {
      // This test used to assert silence, on the reasoning that announcing a cancel is noise and
      // nothing was written. That holds for a cancel *before* any work — but by this point the
      // backup has been built, and encrypted for a sensitive selection, behind a "Creating backup…"
      // spinner. Ending visible work with no result at all left the user unable to tell a cancelled
      // save from a finished one, which is exactly what AGENTS.md's app-wide feedback rule forbids.
      files.saveResult = const BackupSaveResult(BackupSaveOutcome.cancelled);
      await pump(tester);
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();

      expect(vm.error, isNull, reason: 'the user chose this; it is not a failure');
      expect(vm.status, contains('cancelled'));
      expect(vm.status, contains('Nothing was written'));
      await finish(tester);
    });

    testWidgets('a cancelled save clears a previous success message', (tester) async {
      await pump(tester);
      await selectOnly(tester, BackupSection.wolTargets);

      files.saveResult = const BackupSaveResult(BackupSaveOutcome.saved, location: 'somewhere');
      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();
      expect(vm.status, contains('backup written'));

      files.saveResult = const BackupSaveResult(BackupSaveOutcome.cancelled);
      await tapExportWithPassphrase(tester);
      await tester.pumpAndSettle();

      expect(
        vm.status,
        isNot(contains('backup written')),
        reason: 'the old success must not survive',
      );
      expect(vm.status, 'Backup cancelled. Nothing was written.');
      await finish(tester);
    });

    testWidgets('cancelling the passphrase says so instead of nothing', (tester) async {
      await repo.insertServer(server(name: 'nas'));
      await pump(tester);
      await openSections(tester);
      await tester.tap(find.byKey(const ValueKey('backup.sections.continue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup.passphrase.field')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('backup.passphrase.cancel')));
      await tester.pumpAndSettle();

      expect(vm.error, isNull, reason: 'the user chose this; it is not a failure');
      expect(vm.status, 'Backup cancelled. Nothing was written.');
      expect(files.saved, isEmpty);
      await finish(tester);
    });

    testWidgets('an empty chosen file is an actionable error, not silence', (tester) async {
      // Picking a file and having nothing happen is the worst of both: the user cannot tell whether
      // the app failed, the file was wrong, or the tap missed.
      files.openContents = '   \n  ';
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('backup.import')));
      await tester.pumpAndSettle();

      expect(find.textContaining('empty'), findsWidgets);
      expect(vm.error, contains('nothing to restore'));
      await finish(tester);
    });

    testWidgets('a failed save is reported rather than looking successful', (tester) async {
      files.saveResult = const BackupSaveResult(
        BackupSaveOutcome.failed,
        error: 'permission denied',
      );
      await pump(tester);
      await selectOnly(tester, BackupSection.wolTargets);

      await tapExportWithPassphrase(tester);
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

    testWidgets('cancelling the open picker changes nothing and says so', (tester) async {
      files.openContents = null;
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('backup.import')));
      await tester.pumpAndSettle();

      expect(vm.error, isNull);
      expect(vm.status, 'Restore cancelled. Nothing was changed.');
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

      vm.reportSaved('/tmp/omniterm_backup_1.json', encrypted: true);
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
