import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:omniterm/main.dart' as app;

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
    app.main();
    await $.pumpAndSettle();
    await $(const ValueKey('nav.tools')).tap();
    await $(const ValueKey('tools.backup')).tap();
  }

  /// Selects only Settings.
  ///
  /// Deliberately the one section that is *not* sensitive: everything else demands a passphrase
  /// first, and this flow is about the picker, not the passphrase dialog.
  Future<void> selectSettingsOnly(PatrolIntegrationTester $) async {
    await $(const ValueKey('backup.selectNone')).tap();
    await $(const ValueKey('backup.section.settings')).tap();
  }

  patrolTest('cancelling the save claims nothing was written', ($) async {
    // The failure this guards against is a screen that reports success on the way *into* the
    // picker rather than on the way out of it — "Backup ready." left standing over a file that was
    // never written, pointing the user at a backup they do not have.
    await openBackup($);
    await selectSettingsOnly($);

    expect($(const ValueKey('backup.sensitiveNote')).exists, false,
        reason: 'Settings alone carries no credentials, so no passphrase should be demanded');

    await $(const ValueKey('backup.export')).tap();

    // The picker belongs to another app, so this is the only way to know it opened at all.
    await $.platformAutomator.android.waitUntilVisible(
      AndroidSelector(applicationPackage: 'com.google.android.documentsui'),
      timeout: const Duration(seconds: 20),
    );

    await $.platformAutomator.android.pressBack();
    await $.pumpAndSettle();

    expect($(const ValueKey('backup.message')).exists, false,
        reason: 'a cancelled save must not report a backup that does not exist');
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
    await $(const ValueKey('backup.export')).tap();

    await $.platformAutomator.android.waitUntilVisible(
      AndroidSelector(applicationPackage: 'com.google.android.documentsui'),
      timeout: const Duration(seconds: 20),
    );

    final views = await $.platformAutomator.android.getNativeViews(
      AndroidSelector(applicationPackage: 'com.google.android.documentsui'),
    );

    // The picker's view tree, flattened — the file-name field is somewhere inside it and its exact
    // position is the picker's business, not ours.
    final text = StringBuffer();
    void walk(AndroidNativeView view) {
      text.write('${view.text ?? ''} ${view.contentDescription ?? ''} ');
      view.children.forEach(walk);
    }

    views.roots.forEach(walk);
    expect(text.toString(), contains('omniterm'),
        reason: 'the picker must open on a name that identifies the app, not an anonymous default');

    await $.platformAutomator.android.pressBack();
    await $.pumpAndSettle();
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

    await $.platformAutomator.android.pressBack();
    await $.pumpAndSettle();

    expect($(const ValueKey('backup.message')).exists, false,
        reason: 'a cancelled restore must not report one that did not happen');
    expect(
      $.tester
          .widget<OutlinedButton>($(const ValueKey('backup.import')).finder)
          .onPressed,
      isNotNull,
      reason: 'the screen must be usable again after a cancelled restore',
    );
  });
}
