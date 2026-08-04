import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:omniterm/main.dart' as app;

/// The notification-permission dialog, driven for real — Patrol's native half.
///
/// **This is why Patrol was chosen over plain `integration_test` (§11).** The permission dialog is
/// drawn by the system, not by Flutter, so it does not exist in the widget tree at all: a Dart-only
/// flow cannot see it, tap it, or tell granted from denied. Everything here was previously
/// unreachable by any automated test.
///
/// What it pins is §17 made concrete: **the app warns, it does not block.** Refusing notifications
/// must leave alerting fully working — rules still evaluate, incidents are still recorded — and the
/// screen must say plainly that the user will only see them inside the app. An app that quietly
/// does nothing after a denied permission is the failure this exists to catch, and it is invisible
/// from the inside.
void main() {
  /// Turns alerts on, having first made sure they are off.
  ///
  /// Alerts default to **on**, so a blind tap turns them *off* — and turning them off asks for
  /// nothing, which is correct behaviour and a flow that silently proves nothing. The permission is
  /// requested on the off→on edge, deliberately: the system prompt then arrives with the context
  /// that explains it instead of at launch, out of nowhere.
  Future<void> turnAlertsOn(PatrolIntegrationTester $) async {
    final toggle = $(const ValueKey('alerts.masterSwitch.toggle'));
    if ($.tester.widget<Switch>(toggle.finder).value) {
      await toggle.tap();
      await $.pumpAndSettle();
    }
    await toggle.tap();
  }

  /// Patrol clears app data between tests (`clearPackageData`), so each flow starts from a fresh
  /// install and the permission is genuinely unanswered rather than remembered from the last run.
  patrolTest('denying notifications leaves alerting working, and says so', ($) async {
    app.main();
    await $.pumpAndSettle();

    await $(const ValueKey('nav.tools')).tap();
    await $(const ValueKey('tools.alerts')).tap();

    await turnAlertsOn($);

    // Asserted, not assumed. If no dialog appears the app is not asking, which on Android 13+ means
    // it can never notify — and every assertion below would still pass while the feature was dead.
    expect(
      await $.platformAutomator.mobile.isPermissionDialogVisible(
        timeout: const Duration(seconds: 10),
      ),
      true,
      reason: 'turning alerts on must ask for permission to notify',
    );

    await $.platformAutomator.mobile.denyPermission();
    await $.pumpAndSettle();

    // The screen must not pretend everything is fine.
    expect(
      $(const ValueKey('alerts.notificationWarning')).exists,
      true,
      reason: 'a blocked notification permission has to be visible somewhere',
    );

    // And it must say the useful half, not just the bad news: alerting still works, the user will
    // simply only see it in here. "Notifications are blocked" on its own reads as "alerts are off".
    // `textContaining`, not Patrol's bare string finder, which matches a Text's whole value.
    expect(
      $(find.textContaining('Rules still fire')).exists,
      true,
      reason: 'the warning must say alerting still works, not merely that it is blocked',
    );

    // …and alerting must still be on. Switching it off on the user's behalf because the OS said no
    // would be the app deciding that a feature it can still deliver is not worth delivering.
    expect($(const ValueKey('alerts.tabs')).exists, true);
    expect(
      $.tester.widget<Switch>($(const ValueKey('alerts.masterSwitch.toggle')).finder).value,
      true,
      reason: 'a denied permission must not switch alerting off',
    );

    // Rules are still creatable — the add button lives on the Rules tab.
    await $(const ValueKey('alerts.tab.rules')).tap();
    expect(
      $(const ValueKey('alerts.addRule')).exists,
      true,
      reason: 'rules must still be creatable with notifications denied',
    );
  });

  patrolTest('granting notifications clears the warning', ($) async {
    app.main();
    await $.pumpAndSettle();

    await $(const ValueKey('nav.tools')).tap();
    await $(const ValueKey('tools.alerts')).tap();
    await turnAlertsOn($);

    expect(
      await $.platformAutomator.mobile.isPermissionDialogVisible(
        timeout: const Duration(seconds: 10),
      ),
      true,
      reason: 'turning alerts on must ask for permission to notify',
    );
    await $.platformAutomator.mobile.grantPermissionWhenInUse();
    await $.pumpAndSettle();

    expect(
      $(const ValueKey('alerts.notificationWarning')).exists,
      false,
      reason: 'nothing is blocked, so there is nothing to warn about',
    );
    expect($(const ValueKey('alerts.tabs')).exists, true);
  });
}
