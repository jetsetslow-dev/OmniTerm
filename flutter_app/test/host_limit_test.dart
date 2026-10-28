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
}
