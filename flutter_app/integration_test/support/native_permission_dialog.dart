import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

enum NativePermissionDecision { deny, allow }

/// Observes the result of a permission action within the caller's existing deadline.
///
/// Patrol's legacy UiObject click can return without dismissing a freshly drawn permission
/// window. Repeat the same decision only while that modal remains, then let the caller assert
/// the app's actual permission result. A successful automation call alone is not that result.
Future<void> settleNativePermissionDialog(
  PatrolIntegrationTester $, {
  required NativePermissionDecision decision,
  required DateTime deadline,
  Duration lookupTimeout = const Duration(seconds: 5),
}) async {
  Duration remaining([Duration? maximum]) {
    final left = deadline.difference(DateTime.now());
    expect(left, greaterThan(Duration.zero), reason: 'the permission deadline still applies');
    return maximum != null && left > maximum ? maximum : left;
  }

  var visible = await $.platformAutomator.mobile.isPermissionDialogVisible(
    timeout: remaining(lookupTimeout),
  );
  if (!visible) return;
  while (visible) {
    final timeout = remaining();
    final action = switch (decision) {
      NativePermissionDecision.deny => $.platformAutomator.mobile.denyPermission(),
      NativePermissionDecision.allow => $.platformAutomator.mobile.grantPermissionWhenInUse(),
    };
    await action.timeout(timeout);
    visible = await $.platformAutomator.mobile.isPermissionDialogVisible(
      timeout: remaining(const Duration(milliseconds: 200)),
    );
  }
  // The permission callback can start work whose progress stays animated behind DocumentsUI.
  // Observe that work through the caller's result/picker deadline instead of waiting for every
  // Flutter animation to stop while the native surface is still intentionally open.
  await $.tester.pump();
}
