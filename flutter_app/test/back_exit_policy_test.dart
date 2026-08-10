import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/back_exit_policy.dart';

/// Root-level back behaviour, ported from the `BackHandler` in `ui/AppUi.kt:482`.
///
/// The first port dropped both guards: `PopScope` let the platform pop as soon as the in-app history
/// was empty, so a single stray back press at the root exited the app and killed every live SSH
/// session with no warning and nothing to undo.
void main() {
  group('decideBackExit', () {
    test('a first press only warns', () {
      expect(
        decideBackExit(msSinceLastBackPress: null, hasLiveSessions: false),
        BackExitAction.warn,
      );
    });

    test('a first press warns even with sessions running', () {
      // The session check belongs on the second press. Warning about live sessions before the user
      // has shown any intent to leave would fire on every accidental swipe.
      expect(
        decideBackExit(msSinceLastBackPress: null, hasLiveSessions: true),
        BackExitAction.warn,
      );
    });

    test('a second press inside the window exits when nothing is running', () {
      expect(
        decideBackExit(msSinceLastBackPress: 500, hasLiveSessions: false),
        BackExitAction.exit,
      );
    });

    test('a second press asks first when something is still connected', () {
      expect(
        decideBackExit(msSinceLastBackPress: 500, hasLiveSessions: true),
        BackExitAction.confirm,
      );
    });

    test('the window expires, and a late press is a first press again', () {
      // Otherwise a back press from ten minutes ago would still be armed, and the "double press"
      // guard would protect nothing.
      expect(
        decideBackExit(
          msSinceLastBackPress: backExitDoublePressWindowMs + 1,
          hasLiveSessions: false,
        ),
        BackExitAction.warn,
      );
    });

    test('the window boundary is exclusive, matching Kotlin', () {
      // Kotlin compares `currentTime - backPressDisabledTime < 2000`.
      expect(
        decideBackExit(
          msSinceLastBackPress: backExitDoublePressWindowMs,
          hasLiveSessions: false,
        ),
        BackExitAction.warn,
      );
      expect(
        decideBackExit(
          msSinceLastBackPress: backExitDoublePressWindowMs - 1,
          hasLiveSessions: false,
        ),
        BackExitAction.exit,
      );
    });

    test('the window is two seconds', () {
      expect(backExitDoublePressWindowMs, 2000);
    });
  });
}
