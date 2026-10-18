import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:provider/provider.dart';

import 'package:omniterm/main.dart' as app;
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/domain/backup_selection.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';

import '../support/native_permission_dialog.dart';

/// The system document picker, driven for real — Patrol's native half.
///
/// **The picker is another app.** `ACTION_CREATE_DOCUMENT` hands the save over to the platform's
/// Files UI, which is not in this app's widget tree and not in this app's process. A Dart-only flow
/// cannot see it at all, so everything that happens after "Create backup" — including whether the
/// screen tells the truth about it afterwards — has never been covered by anything.
///
/// That matters here more than on most screens. A backup can carry every credential the user has,
/// which is why the app hands bytes to the system picker instead of choosing a path itself: the
/// user decides where the file lands, and the app never gains standing access to a directory it was
/// not given.
void main() {
  Future<void> openBackup(PatrolIntegrationTester $) async {
    // Android's native automator enables platform accessibility the first time it inspects another
    // app. Hide that asynchronous platform request; the suite-owned handle below makes semantics
    // availability deterministic before testWidgets records each test's baseline.
    $.tester.binding.platformDispatcher.semanticsEnabledTestValue = false;
    await app.main();
    await $.pumpAndSettle();
    // Flutter frames do not establish Android's interactive window registration. Hosted runs
    // displayed this Activity while accessibility could not resolve its window. Drive an actual
    // foreground transition after Patrol connects, then require the native app root before a
    // permission or DocumentsUI transition. The launch intent preserves this task and its data.
    await $.platformAutomator.android.pressHome();
    await $.platformAutomator.android.openApp(appId: 'com.jetsetslow.omniterm.app.flutter');
    await $.pumpAndSettle();
    await $.platformAutomator.android.waitUntilVisible(
      AndroidSelector(applicationPackage: 'com.jetsetslow.omniterm.app.flutter'),
      timeout: const Duration(seconds: 10),
    );
    await $(const ValueKey('nav.tools')).tap();
    await $(const ValueKey('tools.backup')).tap();
  }

  /// Selects only Settings, the smallest export. Like Kotlin, every non-empty backup is encrypted,
  /// so export flows answer the passphrase dialog with [enterPassphrase] before the picker opens.
  Future<void> selectSettingsOnly(PatrolIntegrationTester $) async {
    await $(const ValueKey('backup.selectNone')).tap();
    await $(const ValueKey('backup.section.settings')).scrollTo().tap();
    final context = $.tester.element($(const ValueKey('backup.list')).finder);
    final vm = context.read<BackupViewModel>();
    expect(vm.selection.sections, {BackupSection.settings});
    expect(vm.canExport, isTrue, reason: 'Settings must remain selected before export');
    expect(vm.requiresPassphrase, isTrue);
  }

  Future<void> enterPassphrase(PatrolIntegrationTester $) async {
    await $(const ValueKey('backup.passphrase.field')).enterText('a-long-enough-passphrase');
    await $(const ValueKey('backup.passphrase.confirm')).tap();
  }

  /// Answers the notification-permission prompt, which a first backup raises before the picker.
  ///
  /// This used to be handled *after* `pressBack` in [cancelPicker], with the comment that Android
  /// "can place that prompt behind DocumentsUI; after Back it becomes the foreground Activity and
  /// Flutter cannot scroll or animate until it is answered". That was the defect being worked
  /// around: the export now settles the permission before opening the picker, so the prompt is
  /// answered here, at the point it actually appears. Denial is exercised on purpose — a backup
  /// must work without notification permission.
  Future<void> answerNotificationPromptIfShown(PatrolIntegrationTester $, {DateTime? deadline}) =>
      settleNativePermissionDialog(
        $,
        decision: NativePermissionDecision.deny,
        deadline: deadline ?? DateTime.now().add(const Duration(seconds: 5)),
      );

  Future<void> cancelPicker(PatrolIntegrationTester $) async {
    await $.platformAutomator.android.pressBack();
    // Kept tolerant: if a prompt ever does end up behind the picker again, answering it here stops
    // a native modal being left over a supposedly usable app.
    await answerNotificationPromptIfShown($);
    await $.pumpAndSettle();
  }

  Future<void> waitForSavePicker(PatrolIntegrationTester $) async {
    final context = $.tester.element($(const ValueKey('backup.list')).finder);
    final vm = context.read<BackupViewModel>();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    await answerNotificationPromptIfShown($, deadline: deadline);
    // Native visibility polling does not pump Flutter frames or wait for the SQLite reads that
    // build the backup. The permission reply can arrive after pumpAndSettle has returned. Wait
    // for that export to start and finish before handing the observation over to Android, using
    // the same twenty-second budget rather than extending the picker deadline.
    while ((vm.busyMessage != 'Creating backup…' || vm.busy) &&
        vm.error == null &&
        DateTime.now().isBefore(deadline)) {
      await $.tester.pump(const Duration(milliseconds: 100));
      await $.tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(vm.error, isNull, reason: 'the backup must be built before its save picker opens');
    expect(vm.busyMessage, 'Creating backup…', reason: 'the export must actually have started');
    expect(
      vm.busy,
      false,
      reason: 'the backup reads must finish before checking the native picker',
    );
    final remaining = deadline.difference(DateTime.now());
    expect(
      remaining,
      greaterThan(Duration.zero),
      reason: 'the original picker deadline still applies',
    );
    await $.platformAutomator.android.waitUntilVisible(
      AndroidSelector(applicationPackage: 'com.google.android.documentsui'),
      timeout: remaining,
    );
  }

  patrolTest('backup selection storage shows progress, failure and retry', ($) async {
    await openBackup($);
    final context = $.tester.element($(const ValueKey('backup.list')).finder);
    final db = context.read<AppDatabase>();
    final vm = context.read<BackupViewModel>();
    final previous = await db.appDataDao.getSetting('backup_export_selection');
    final held = Completer<void>();
    final release = Completer<void>();
    Future<void>? transaction;
    try {
      await db.customStatement(
        "CREATE TRIGGER reject_backup_selection BEFORE INSERT ON app_settings "
        "WHEN NEW.`key` = 'backup_export_selection' "
        "BEGIN SELECT RAISE(ABORT, 'fixture selection unavailable'); END",
      );
      transaction = db.transaction(() async {
        await db.customSelect('SELECT 1').get();
        held.complete();
        await release.future;
      });
      try {
        await held.future.timeout(const Duration(seconds: 10));
        // Tap without waiting for animations: the pending write deliberately keeps progress active.
        await $.tester.tap(find.byKey(const ValueKey('backup.selectAll')));
        await $.tester.pump();
        expect(
          find.text('Remembering backup selection…'),
          findsOneWidget,
          reason: 'a held settings write must show progress before it completes',
        );
      } finally {
        release.complete();
        await transaction;
      }
      Future<void> waitFor(Finder finder) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await $.tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsOneWidget);
      }

      await waitFor(find.byKey(const ValueKey('backup.selection.error')));
      expect(vm.selection.contains(BackupSection.crashLogs), isTrue);
      expect((await db.appDataDao.getSetting('backup_export_selection'))?.value, previous?.value);
      await db.customStatement('DROP TRIGGER reject_backup_selection');
      await $.tester.tap(find.byKey(const ValueKey('backup.selection.retry')));
      await $.pumpAndSettle();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((await db.appDataDao.getSetting('backup_export_selection'))?.value !=
              vm.selection.encode() &&
          DateTime.now().isBefore(deadline)) {
        await $.tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        (await db.appDataDao.getSetting('backup_export_selection'))?.value,
        vm.selection.encode(),
      );
      await $.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup.selection.error')), findsNothing);
      expect(find.text('Remembering backup selection…'), findsNothing);
    } finally {
      if (!release.isCompleted) release.complete();
      if (transaction != null) await transaction;
      await db.customStatement('DROP TRIGGER IF EXISTS reject_backup_selection');
      if (previous == null) {
        await db.customStatement(
          "DELETE FROM app_settings WHERE `key` = 'backup_export_selection'",
        );
      } else {
        await db.customStatement(
          'INSERT OR REPLACE INTO app_settings (`key`, value) VALUES (?, ?)',
          [previous.key, previous.value],
        );
      }
    }
  });

  // A focused control can run this one device regression on the original implementation.
  if (const bool.fromEnvironment('OMNITERM_E2E_BACKUP_PERSISTENCE_ONLY')) return;

  patrolTest('cancelling the save claims nothing was written', ($) async {
    // The failure this guards against is a screen that reports success on the way *into* the
    // picker rather than on the way out of it — "Backup ready." left standing over a file that was
    // never written, pointing the user at a backup they do not have.
    await openBackup($);
    await selectSettingsOnly($);

    expect(
      $(const ValueKey('backup.sensitiveNote')).exists,
      true,
      reason: 'Kotlin encrypts every backup, settings included, so the passphrase is explained',
    );

    // Scrolled to, like `backup.import` below. The Backup screen is a `ListView`, so a control past
    // the fold is not merely off-screen — it has never been built, and the finder reports zero
    // widgets rather than an invisible one. Both of these failed exactly there the first time these
    // tests were ever executed.
    await $(const ValueKey('backup.export')).scrollTo().tap();
    await enterPassphrase($);

    // Settle permission and require the actual platform picker within one unchanged budget.
    await waitForSavePicker($);

    await cancelPicker($);

    // This asserted that no message existed at all, which was a fair proxy while the only message
    // the screen could show was a success claim. It no longer is: a cancelled save now says so
    // explicitly, because the backup had already been built behind a spinner and ending that with
    // silence left the user unable to tell a cancelled save from a finished one. The property this
    // test protects is unchanged and is now checked directly — and more strictly, since it would
    // also catch a message that wrongly claimed success.
    final message = $.tester
        .widget<Text>(
          find.descendant(
            of: $(const ValueKey('backup.message')).finder,
            matching: find.byType(Text),
          ),
        )
        .data;
    expect(
      message,
      isNot(contains('Backup saved')),
      reason: 'a cancelled save must not report a backup that does not exist',
    );
    expect(
      message,
      contains('Nothing was written'),
      reason: 'and it must say what did happen, rather than leaving finished work unexplained',
    );
    // Completion reveals feedback at the top of the lazy list. The export control has been
    // disposed off-screen; scroll it back into view before checking that it is enabled again.
    await $(const ValueKey('backup.export')).scrollTo();
    expect(
      $.tester.widget<FilledButton>($(const ValueKey('backup.export')).finder).onPressed,
      isNotNull,
      reason: 'the screen must be usable again after a cancelled save',
    );
  });

  patrolTest('the picker is offered the file name the backup should have', ($) async {
    // The suggested name is what the user sees first in the picker and what they will search for
    // later. Getting it from the app rather than letting the picker default to "download" is the
    // difference between a findable backup and an anonymous blob.
    await openBackup($);
    await selectSettingsOnly($);
    await $(const ValueKey('backup.export')).scrollTo().tap();
    await enterPassphrase($);

    await waitForSavePicker($);

    // Query the filename leaf directly. Asking UIAutomator for the DocumentsUI package root makes
    // Patrol recursively serialize every descendant; Samsung's API 36 picker can mutate that tree
    // while it is being walked, leaving the native request hung until Patrol's 60-second transport
    // timeout. The filename field is the contract this test actually needs and has no descendants.
    const filename = AndroidSelector(
      applicationPackage: 'com.google.android.documentsui',
      className: 'android.widget.EditText',
    );
    await $.platformAutomator.android.waitUntilVisible(
      filename,
      timeout: const Duration(seconds: 20),
    );
    final views = await $.platformAutomator.android.getNativeViews(filename);
    expect(
      views.roots.single.text,
      matches(RegExp(r'^omniterm_backup_\d{10}\.json$')),
      reason:
          'the picker must receive Kotlin\'s omniterm_backup_<seconds>.json name, not a default',
    );

    await cancelPicker($);
  });

  patrolTest('cancelling the restore picker changes nothing', ($) async {
    // The mirror of the save case, and the more dangerous half: restoring *adds* rows, so a screen
    // that reported "Restored N items" over a picker the user backed out of would send someone
    // hunting through their hosts for entries that were never added.
    await openBackup($);
    // Restore lives below the export half of a long screen, and Patrol only taps what is actually
    // hit-testable.
    await $(const ValueKey('backup.import')).scrollTo().tap();

    await $.platformAutomator.android.waitUntilVisible(
      AndroidSelector(applicationPackage: 'com.google.android.documentsui'),
      timeout: const Duration(seconds: 20),
    );

    await cancelPicker($);

    expect(
      $(const ValueKey('backup.message')).exists,
      false,
      reason: 'a cancelled restore must not report one that did not happen',
    );
    await $(const ValueKey('backup.import')).scrollTo();
    expect(
      $.tester.widget<OutlinedButton>($(const ValueKey('backup.import')).finder).onPressed,
      isNotNull,
      reason: 'the screen must be usable again after a cancelled restore',
    );
  });

  // `patrolTest` has initialized PatrolBinding by the time registration reaches this line, while
  // no test can execute until main returns. Owning one handle now prevents Android accessibility
  // from adding the first handle just after testWidgets records zero (a first-test-only failure).
  final binding = WidgetsBinding.instance;
  binding.platformDispatcher.onSemanticsEnabledChanged = () {};
  final suiteSemantics = binding.ensureSemantics();
  tearDownAll(suiteSemantics.dispose);
}
