import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/shell_state.dart';

void main() {
  group('keep screen on completion', () {
    test('failure preserves the acknowledged flag and can be retried', () async {
      var fail = true;
      final state = ShellState(
        keepScreenOnSetter: (_) async {
          if (fail) throw StateError('platform unavailable');
        },
      );
      addTearDown(state.dispose);
      final operation = state.setKeepScreenOnDirect(true);
      expect(state.isSettingKeepScreenOn, isTrue);
      await operation;
      expect(state.isSettingKeepScreenOn, isFalse);
      expect(state.isKeepScreenOnEnabled, isFalse);
      expect(state.keepScreenOnError, contains('platform unavailable'));
      fail = false;
      state.retryKeepScreenOn();
      expect(state.keepScreenOnError, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(state.isKeepScreenOnEnabled, isTrue);
      expect(state.isSettingKeepScreenOn, isFalse);
    });

    test('a disable failure keeps the acknowledged enabled state', () async {
      final state = ShellState(
        keepScreenOnSetter: (enabled) async {
          if (!enabled) throw StateError('disable refused');
        },
      );
      addTearDown(state.dispose);
      await state.setKeepScreenOnDirect(true);
      await state.setKeepScreenOnDirect(false);
      expect(state.isKeepScreenOnEnabled, isTrue);
      expect(state.keepScreenOnError, contains('disable refused'));
      state.dismissKeepScreenOnError();
      expect(state.keepScreenOnError, isNull);
    });

    test('battery-saver or settings changes serialize behind a pending write', () async {
      final gates = [Completer<void>(), Completer<void>()];
      final calls = <bool>[];
      final state = ShellState(
        keepScreenOnSetter: (enabled) {
          calls.add(enabled);
          return gates[calls.length - 1].future;
        },
      );
      addTearDown(state.dispose);
      final first = state.setKeepScreenOnDirect(true);
      final last = state.setKeepScreenOnDirect(false);
      expect(calls, [true]);
      state.requestKeepScreenOnToggle();
      expect(state.showKeepScreenOnWarning, isFalse);
      gates[0].complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, [true, false]);
      expect(state.isSettingKeepScreenOn, isTrue);
      expect(state.isKeepScreenOnEnabled, isTrue);
      gates[1].complete();
      await Future.wait([first, last]);
      expect(state.isKeepScreenOnEnabled, isFalse);
      expect(state.isSettingKeepScreenOn, isFalse);
    });

    test('a superseded failure leaves the newer acknowledged request intact', () async {
      final gate = Completer<void>();
      final state = ShellState(keepScreenOnSetter: (_) => gate.future);
      addTearDown(state.dispose);
      final first = state.setKeepScreenOnDirect(true);
      final last = state.setKeepScreenOnDirect(false);
      gate.completeError(StateError('enable refused'));
      await Future.wait([first, last]);
      expect(state.isKeepScreenOnEnabled, isFalse);
      expect(state.keepScreenOnError, isNull);
      expect(state.isSettingKeepScreenOn, isFalse);
    });

    test('a platform completion after disposal cannot notify or queue another write', () async {
      final gate = Completer<void>();
      var calls = 0;
      var notifications = 0;
      final state = ShellState(
        keepScreenOnSetter: (_) {
          calls++;
          return gate.future;
        },
      );
      state.addListener(() => notifications++);
      final operation = state.setKeepScreenOnDirect(true);
      final last = state.setKeepScreenOnDirect(false);
      final beforeDispose = notifications;
      state.dispose();
      gate.complete();
      await Future.wait([operation, last]);
      await state.setKeepScreenOnDirect(true);
      expect(notifications, beforeDispose);
      expect(calls, 1);
    });

    test('enabling stays off until the platform acknowledges it', () async {
      final gate = Completer<void>();
      final state = ShellState(keepScreenOnSetter: (_) => gate.future);
      addTearDown(state.dispose);
      state.setKeepScreenOnDirect(true);
      final enabledWhilePending = state.isKeepScreenOnEnabled;
      gate.complete();
      await gate.future;
      await Future<void>.delayed(Duration.zero);
      expect(enabledWhilePending, isFalse);
      expect(state.isKeepScreenOnEnabled, isTrue);
    });

    test('disabling stays on until the platform acknowledges it', () async {
      final gate = Completer<void>();
      final state = ShellState(
        keepScreenOnSetter: (enabled) async {
          if (!enabled) await gate.future;
        },
      );
      addTearDown(state.dispose);
      state.setKeepScreenOnDirect(true);
      await Future<void>.delayed(Duration.zero);
      state.setKeepScreenOnDirect(false);
      final enabledWhilePending = state.isKeepScreenOnEnabled;
      gate.complete();
      await gate.future;
      await Future<void>.delayed(Duration.zero);
      expect(enabledWhilePending, isTrue);
      expect(state.isKeepScreenOnEnabled, isFalse);
    });
  });

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
