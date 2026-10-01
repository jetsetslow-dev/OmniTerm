import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:provider/provider.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/host_status_probe.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:omniterm/ui/view_model/telemetry_poller.dart';

void main() {
  patrolTest(
    'Settings preserves Kotlin editing, PIN and Back behavior at phone size',
    ($) async {
      await app.main();
      await $.pumpAndSettle();
      final context = $.tester.element(find.byKey(const ValueKey('screen.servers')));
      final state = context.read<AppState>();
      final settings = context.read<SettingsViewModel>();
      final lock = context.read<AppLockController>();
      context.read<HostStatusProbe>().stop();
      context.read<TelemetryPoller>().stop();
      await $.tester.runAsync(settings.start);
      expect(lock.hasStoredPin, isFalse, reason: 'Requires the disposable clean app fixture');
      final original = settings.saved;
      var createdPin = false;
      Finder key(String value) => find.byKey(ValueKey(value));
      final settingsList = find.descendant(
        of: key('settings.list'),
        matching: find.byType(Scrollable),
      );
      Future<void> scrollSettingsTo(
        Finder target, {
        AxisDirection direction = AxisDirection.down,
      }) => $(target).scrollTo(
        view: settingsList,
        scrollDirection: direction,
        // The SFTP card is several screens below the first card. Keep small drags so a
        // short control cannot be skipped, but traverse the full list when necessary.
        step: 64,
        maxScrolls: 100,
      );
      Future<void> tap(String value, {AxisDirection direction = AxisDirection.down}) async {
        final target = key(value);
        // Modal buttons already visible must not try to scroll the obscured Settings list.
        if (target.hitTestable().evaluate().isEmpty) {
          if (settingsList.evaluate().isNotEmpty && value.startsWith('settings.')) {
            await scrollSettingsTo(target, direction: direction);
          } else {
            await $(target).scrollTo(scrollDirection: direction);
          }
        }
        await $(target).tap();
      }

      FilledButton save() => $.tester.widget<FilledButton>(key('settings.save'));
      Future<void> waitForSave() async {
        // The progress bar is in the lazily built list and can be offscreen. Animation
        // settling alone does not wait for database IO; the sticky button reflects the
        // complete operation, including the subsequent app-lock refresh or PIN cleanup.
        await $(
          find.descendant(of: key('settings.save'), matching: find.text('Save changes')),
        ).waitUntilVisible();
        expect(settings.isDirty, isFalse);
        expect(save().onPressed, isNull);
        expect(key('settings.save.error'), findsNothing);
      }

      try {
        await tap('nav.tools');
        await tap('tools.settings');
        expect(find.text('SECURITY GATE APP LOCK'), findsOneWidget);
        expect(find.text('Save changes'), findsOneWidget);
        expect(save().onPressed, isNull);

        // PIN setup is immediate. Cancelling must leave security unchanged.
        await tap('settings.appLockEnabled');
        expect(find.text('Configure Security PIN'), findsOneWidget);
        expect(key('settings.pin.second'), findsNothing);
        await tap('settings.pin.cancel');
        expect(lock.hasStoredPin, isFalse);
        expect(settings.isDirty, isFalse);

        await tap('settings.darkMode');
        expect(find.text('System Default'), findsOneWidget);
        expect(find.text('Dark Theme'), findsOneWidget);
        expect(find.text('Light Theme'), findsOneWidget);
        await $.platformAutomator.android.pressBack();
        await $.pumpAndSettle();
        expect(settings.isDirty, isFalse);

        await tap('settings.keepScreenOn');
        expect(settings.isDirty, isTrue);
        await tap('settings.back');
        expect(key('navigation.settingsDiscard'), findsOneWidget);
        await tap('navigation.settings.keepEditing');
        expect(settings.isDirty, isTrue);
        await tap('settings.revert');
        expect(settings.isDirty, isFalse);

        await scrollSettingsTo(key('settings.sftpWarnFileCount'));
        await $.tester.enterText(key('settings.sftpWarnFileCount'), '');
        await $.pumpAndSettle();
        expect(save().onPressed, isNull);
        await $.tester.enterText(key('settings.sftpWarnFileCount'), '99999');
        await $.pumpAndSettle();
        expect(
          $.tester.widget<TextField>(key('settings.sftpWarnFileCount')).controller!.text,
          '99999',
        );
        await tap('settings.save');
        await waitForSave();
        expect(key('settings.save.progress'), findsNothing);
        expect(key('settings.save.error'), findsNothing);
        expect(settings.saved.sftpWarnFileCount, 10000);
        expect(
          $.tester.widget<TextField>(key('settings.sftpWarnFileCount')).controller!.text,
          '10000',
        );
        expect(await state.repository.getSetting('sftp_large_batch_file_threshold'), '10000');

        // Return upward from the last card, using the actual scroll gesture.
        // The security setup persists immediately without applying unrelated edits.
        await tap('settings.keepScreenOn', direction: AxisDirection.up);
        final savedKeepOn = settings.saved.keepScreenOn;
        await tap('settings.appLockEnabled', direction: AxisDirection.up);
        await $.tester.enterText(key('settings.pin.first'), '4913');
        await $.pumpAndSettle();
        createdPin = true;
        await tap('settings.pin.confirm');
        expect(lock.hasStoredPin, isTrue);
        expect(settings.saved.appLockEnabled, isTrue);
        expect(settings.saved.keepScreenOn, savedKeepOn);
        expect(settings.draft.keepScreenOn, !savedKeepOn);

        await tap('settings.save');
        expect(find.text('Authenticate to save'), findsOneWidget);
        await $.tester.enterText(key('sudoAuth.pin'), '4913');
        await $.pumpAndSettle();
        await tap('sudoAuth.confirm');
        await waitForSave();
        expect(key('settings.save.progress'), findsNothing);
        expect(key('settings.save.error'), findsNothing);
        expect(settings.isDirty, isFalse);
        expect(settings.saved.keepScreenOn, !savedKeepOn);

        // Disabling security explains deletion before authenticating it.
        await tap('settings.appLockEnabled');
        await tap('settings.save');
        expect(find.text('Turn off App Lock?'), findsOneWidget);
        await tap('settings.appLockOff.cancel');
        expect(lock.hasStoredPin, isTrue);
        await tap('settings.save');
        await tap('settings.appLockOff.confirm');
        await $.tester.enterText(key('sudoAuth.pin'), '4913');
        await $.pumpAndSettle();
        await tap('sudoAuth.confirm');
        await waitForSave();
        expect(lock.hasStoredPin, isFalse);
        expect(settings.saved.appLockEnabled, isFalse);
        expect(settings.isDirty, isFalse);
        expect($.tester.takeException(), isNull);
      } finally {
        if (createdPin) await $.tester.runAsync(lock.clearPin);
        settings.revert();
        settings.update((_) => original);
        await $.tester.runAsync(settings.save);
        await $.tester.runAsync(lock.refresh);
      }
    },
    skip: !Platform.isAndroid,
  );
}
