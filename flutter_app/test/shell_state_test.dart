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
}
