import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/host_limit.dart';

/// The free-tier host limit's *standing violation* case, ported from `reconcileHostLimit`
/// (`ui/AppViewModel.kt:966`).
///
/// Defect 51 closed the route that creates the condition. This covers an install already in it —
/// which a restore on an older build, a lapsed subscription or a refund can all produce.
void main() {
  group('hostLimitExceeded', () {
    test('an unlimited build never reconciles', () {
      // The source-available build and every unlocked install.
      expect(hostLimitExceeded(hasHostLimit: false, hostLimit: 1, hostCount: 99), isFalse);
    });

    test('at the limit is not over it', () {
      expect(hostLimitExceeded(hasHostLimit: true, hostLimit: 1, hostCount: 1), isFalse);
    });

    test('over the limit reconciles', () {
      expect(hostLimitExceeded(hasHostLimit: true, hostLimit: 1, hostCount: 2), isTrue);
    });

    test('an empty install does not reconcile', () {
      // A fresh limited install has nothing to choose between, and a dialog demanding a choice
      // would be unanswerable.
      expect(hostLimitExceeded(hasHostLimit: true, hostLimit: 1, hostCount: 0), isFalse);
    });
  });

  group('isValidHostKeepSelection', () {
    test('exactly the limit is the only legal answer', () {
      expect(isValidHostKeepSelection(selectedCount: 1, hostLimit: 1), isTrue);
      expect(isValidHostKeepSelection(selectedCount: 2, hostLimit: 2), isTrue);
    });

    test('too many is refused', () {
      expect(isValidHostKeepSelection(selectedCount: 2, hostLimit: 1), isFalse);
    });

    test('too few is refused, including none', () {
      // Keeping fewer would be the app deleting hosts nobody asked it to delete; keeping none would
      // leave an install with nothing in it. Neither is a reconciliation.
      expect(isValidHostKeepSelection(selectedCount: 0, hostLimit: 1), isFalse);
      expect(isValidHostKeepSelection(selectedCount: 1, hostLimit: 2), isFalse);
    });
  });

  group('the wording', () {
    test('a lapsed unlock says something changed', () {
      expect(HostLimitReason.unlockEnded.message(1), contains('no longer active'));
    });

    test('the free tier says what it allows', () {
      expect(HostLimitReason.freeTier.message(1), contains('saves 1 host'));
    });

    test('the noun agrees with the limit', () {
      // A limit of one is the shipping case, but the message must not read "1 hosts" if it changes.
      expect(HostLimitReason.freeTier.message(2), contains('2 hosts'));
      expect(HostLimitReason.unlockEnded.message(1), contains('1 saved host to keep'));
    });
  });

  group('shouldReconcileHostLimit', () {
    bool decide({
      bool playStoreBuild = true,
      bool licenseEnabled = true,
      bool licenseLoading = false,
      bool unlocked = false,
      int hostLimit = 1,
      int hostCount = 3,
    }) => shouldReconcileHostLimit(
      playStoreBuild: playStoreBuild,
      licenseEnabled: licenseEnabled,
      licenseLoading: licenseLoading,
      unlocked: unlocked,
      hostLimit: hostLimit,
      hostCount: hostCount,
    );

    test('a limited build holding too many reconciles', () {
      expect(decide(), isTrue);
    });

    test('the source-available build never does', () {
      expect(decide(playStoreBuild: false), isFalse);
    });

    test('an unlocked entitlement never does', () {
      expect(decide(unlocked: true), isFalse);
    });

    test('billing disabled never does', () {
      expect(decide(licenseEnabled: false), isFalse);
    });

    test('a query still in flight waits', () {
      // Acting mid-query would put a deletion prompt in front of a paying user in the seconds
      // before their unlock is confirmed.
      expect(decide(licenseLoading: true), isFalse);
    });

    test('a build within its limit does not', () {
      expect(decide(hostCount: 1), isFalse);
      expect(decide(hostCount: 0), isFalse);
    });
  });
}
