/// What a back press at the root of the app should do.
///
/// Ported from the `BackHandler` in `ui/AppUi.kt:482`. Kept out of the widget so the rules can be
/// tested without a platform back gesture — and they are rules worth testing, because the failure is
/// silent and expensive: one stray back press killing a running SSH session is not something the
/// user can undo.
library;

/// How long a first back press stays "armed" before the app forgets it, matching Kotlin's 2000 ms.
const backExitDoublePressWindowMs = 2000;

/// The outcome of a back press once the in-app history is exhausted.
enum BackExitAction {
  /// Nothing was consumed and nothing happens yet — warn the user that another press exits.
  warn,

  /// Leave now. Nothing is running that would be lost.
  exit,

  /// Something is still connected; ask before killing it.
  confirm,
}

/// Decides what a root-level back press does.
///
/// [msSinceLastBackPress] is null when there was no previous press, or when it has already been
/// consumed. The double-press window exists because back is the single easiest gesture to hit by
/// accident on a phone, and this app's version of "exit" drops live shells.
///
/// The session check happens on the **second** press, not the first: warning about live sessions
/// before the user has shown any intent to leave would fire on every stray swipe.
BackExitAction decideBackExit({required int? msSinceLastBackPress, required bool hasLiveSessions}) {
  final armed = msSinceLastBackPress != null && msSinceLastBackPress < backExitDoublePressWindowMs;
  if (!armed) return BackExitAction.warn;
  return hasLiveSessions ? BackExitAction.confirm : BackExitAction.exit;
}
