import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/shell_state.dart';

void main() {
  test('free entitlement requires an explicit host choice when data exceeds the limit', () {
    final state = ShellState();
    state.updateLicenseEntitlement(
      enabled: true,
      resolved: true,
      unlocked: false,
      adsRemoved: false,
    );

    state.reconcileHostLimit(2, reason: 'Choose one.');

    expect(state.hostLimitReconciliationRequired, isTrue);
    expect(state.hostLimitReconciliationReason, 'Choose one.');
  });

  test('reconciliation clears after compliance or entitlement restoration', () {
    final state = ShellState();
    state.updateLicenseEntitlement(
      enabled: true,
      resolved: true,
      unlocked: false,
      adsRemoved: false,
    );
    state.reconcileHostLimit(2);
    state.reconcileHostLimit(1);
    expect(state.hostLimitReconciliationRequired, isFalse);

    state.reconcileHostLimit(3);
    state.updateLicenseEntitlement(enabled: true, resolved: true, unlocked: true, adsRemoved: true);
    expect(state.hostLimitReconciliationRequired, isFalse);
  });

  test('source distribution never asks the user to discard hosts', () {
    final state = ShellState();
    state.updateLicenseEntitlement(
      enabled: false,
      resolved: true,
      unlocked: true,
      adsRemoved: true,
    );
    state.reconcileHostLimit(100);
    expect(state.hostLimitReconciliationRequired, isFalse);
  });

  group('pull-to-refresh reporting', () {
    test('a refresh that returns a failure surfaces it', () async {
      final state = ShellState();
      await state.refreshCurrentScreen(() async => 'Refresh problem on 1 host(s): atlas is stuck');
      expect(state.refreshError, 'Refresh problem on 1 host(s): atlas is stuck');
      expect(state.isRefreshing, isFalse);
    });

    test('a clean refresh clears a previous failure', () async {
      final state = ShellState();
      await state.refreshCurrentScreen(() async => 'boom');
      expect(state.refreshError, 'boom');
      await state.refreshCurrentScreen(() async => null);
      expect(state.refreshError, isNull);
    });

    test('a refresh that throws is reported rather than swallowed', () async {
      final state = ShellState();
      await state.refreshCurrentScreen(() async => throw StateError('no route'));
      expect(state.refreshError, contains('no route'));
      expect(state.isRefreshing, isFalse);
    });

    test('the error can be dismissed', () async {
      final state = ShellState();
      await state.refreshCurrentScreen(() async => 'boom');
      state.dismissRefreshError();
      expect(state.refreshError, isNull);
    });

    test('an overlapping refresh is ignored and leaves the reported error alone', () async {
      final state = ShellState();
      await state.refreshCurrentScreen(() async => 'boom');
      final gate = Completer<void>();
      final first = state.refreshCurrentScreen(() async {
        await gate.future;
        return null;
      });
      // While the first is in flight the second must not run at all.
      var secondRan = false;
      await state.refreshCurrentScreen(() async {
        secondRan = true;
        return null;
      });
      expect(secondRan, isFalse);
      gate.complete();
      await first;
      expect(state.refreshError, isNull);
    });
  });
}
