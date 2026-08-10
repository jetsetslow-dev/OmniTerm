import 'package:flutter/foundation.dart';

import '../../data/app_repository.dart';
import '../../domain/app_lock_timeout_policy.dart';
import '../../domain/app_pin.dart';

/// Result of an unlock attempt, so the screen can say which of three different things happened.
enum UnlockOutcome { unlocked, wrongPin, throttled }

/// Asks the platform for a biometric/device-credential check.
///
/// Injected and nullable (Convention 4): with no implementation the lock still works by PIN, and the
/// biometric button is simply absent rather than present and silently doing nothing.
typedef BiometricPrompt = Future<bool> Function(String reason);

/// The app lock: whether the app is currently locked, and everything that decides it.
///
/// Ported from the app-lock parts of `ui/AppViewModel.kt`, with the timeout arithmetic reused from
/// the already-ported [normalizeAppLockBackgroundTimeout]. Kept out of the widget layer because
/// every rule here is one that fails silently when wrong: a lock that never engages looks identical
/// to a lock that works, right up until the phone is lost.
class AppLockController extends ChangeNotifier {
  AppLockController(
    this._repository, {
    this.biometricPrompt,
    int Function()? clock,
    int Function()? monotonicClock,
  }) : _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _monotonicNow = monotonicClock ?? _processElapsedMs;

  final AppRepository _repository;
  final BiometricPrompt? biometricPrompt;

  /// Wall clock. Correct for the PIN throttle, which is **persisted** and so has to survive a
  /// reboot — as it does in the Kotlin, which uses `System.currentTimeMillis()` there too.
  final int Function() _now;

  /// A clock that cannot be moved by the user, for the background lock timer.
  ///
  /// Kotlin uses `SystemClock.elapsedRealtime()` (CLOCK_BOOTTIME) here and documents at
  /// `AppViewModel.kt:833` why nothing else will do: `CLOCK_MONOTONIC` stops while the device is
  /// suspended, so the countdown freezes with the screen off and the app never re-locks; and the
  /// wall clock can simply be wound backwards to bypass the timeout. Dart exposes neither
  /// `elapsedRealtime` nor a suspend-aware monotonic source, so [onForegrounded] takes the **larger**
  /// of the two elapsed times, which fails closed in both directions: the wall clock covers deep
  /// sleep, and this covers the wall clock being tampered with.
  final int Function() _monotonicNow;

  bool _enabled = false;
  bool _useBiometrics = false;
  String? _storedPin;
  int _timeoutMs = defaultAppLockBackgroundTimeoutMs;

  /// True when the lock is configured **and usable** — i.e. a PIN actually exists.
  ///
  /// The two are checked together because "locked with no way to unlock" is not a security feature,
  /// it is a brick. If the setting is on but the PIN row is gone, the lock stays open.
  bool get isConfigured => _enabled && _storedPin != null && _storedPin!.isNotEmpty;

  bool _locked = false;
  bool get isLocked => _locked;
  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// True when biometrics are both enabled and available to try.
  bool get canUseBiometrics => _useBiometrics && biometricPrompt != null;

  int? get pinLength => storedPinLength(_storedPin);

  int _failedAttempts = 0;
  int _lockedUntilMs = 0;

  int get failedAttempts => _failedAttempts;

  /// Milliseconds remaining on the throttle, or 0.
  int get throttleRemainingMs {
    final remaining = _lockedUntilMs - _now();
    return remaining > 0 ? remaining : 0;
  }

  bool get isThrottled => isPinThrottled(_lockedUntilMs, _now());

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Read the configuration and decide the starting state.
  Future<void> load() async {
    _enabled = (await _repository.getSetting('app_lock_enabled')) == 'true';
    _useBiometrics = (await _repository.getSetting('biometrics_enabled')) == 'true';
    _storedPin = await _repository.getSetting('app_pin');
    // `app_lock_grace_ms` is the key the Android app writes, kept there deliberately across its own
    // renames so an upgrade preserves the configured interval. Reading anything else would silently
    // put every migrating user back on the 30-second default — the setting would still be shown as
    // theirs while no longer being the one in force.
    _timeoutMs = normalizeAppLockBackgroundTimeout(
      int.tryParse(await _repository.getSetting('app_lock_grace_ms') ?? ''),
    );
    _failedAttempts = (int.tryParse(await _repository.getSetting('pin_failed_attempts') ?? '') ?? 0)
        .clamp(0, pinMaxAttempts);
    // Restored, not recomputed: a lockout has to outlive the process it was set in.
    _lockedUntilMs = restoredPinLockout(
      int.tryParse(await _repository.getSetting('pin_locked_until') ?? ''),
      _now(),
    );
    // A cold start is always locked when the lock is configured. Anything else would let a
    // force-stop — the easiest thing in the world to do to a phone you have picked up — be a way
    // straight past it.
    _locked = isConfigured;
    _loaded = true;
    _safeNotify();
  }

  /// Re-read after the Settings screen saves, so turning the lock on takes effect immediately.
  Future<void> refresh() async {
    final wasLocked = _locked;
    await load();
    // Reloading must not lock a user out mid-session just because they enabled the setting.
    _locked = wasLocked && isConfigured;
    _safeNotify();
  }

  // ── lifecycle ───────────────────────────────────────────────────────────────

  int? _backgroundedAtMs;
  int? _backgroundedAtMonotonicMs;

  /// The app went to the background.
  ///
  /// [isChangingConfigurations] is Android's rotation/theme re-create, which is not the user
  /// leaving; starting the timer there would lock the app when someone turned their phone sideways.
  void onBackgrounded({bool isChangingConfigurations = false}) {
    if (!shouldRecordAppBackground(isChangingConfigurations: isChangingConfigurations)) return;
    // Only the first transition out counts. The platform sends `inactive` **again on the way back
    // in**, immediately before `resumed`, so assigning unconditionally reset the clock to "now"
    // microseconds before it was read — and the lock silently never engaged, no matter how long the
    // app had been away. `onForegrounded` clears both stamps.
    if (_backgroundedAtMs != null) return;
    _backgroundedAtMs = _now();
    _backgroundedAtMonotonicMs = _monotonicNow();
  }

  /// The app came back to the foreground; lock if it was away long enough.
  void onForegrounded() {
    final since = _backgroundedAtMs;
    final sinceMonotonic = _backgroundedAtMonotonicMs;
    // Consumed unconditionally, even when the lock is off: a stale stamp must never survive to fire
    // on a later, unrelated resume.
    _backgroundedAtMs = null;
    _backgroundedAtMonotonicMs = null;
    if (!isConfigured || _locked || since == null) return;

    // The larger of the two elapsed times. Winding the wall clock back makes its reading small or
    // negative, and the monotonic one still counts; a device suspended in deep sleep freezes the
    // monotonic one, and the wall clock still counts. Neither can shorten the timeout alone.
    final wallElapsed = _now() - since;
    final monotonicElapsed = sinceMonotonic == null ? 0 : _monotonicNow() - sinceMonotonic;
    final elapsed = wallElapsed > monotonicElapsed ? wallElapsed : monotonicElapsed;

    // `>=` rather than `>`: a zero timeout means "lock immediately", and a strict comparison would
    // make the one setting that asks for the most protection the only one that never fires.
    if (elapsed >= _timeoutMs) {
      _locked = true;
      _safeNotify();
    }
  }

  /// Lock now, whatever the timer says.
  void lockNow() {
    if (!isConfigured || _locked) return;
    _locked = true;
    _safeNotify();
  }

  // ── unlocking ───────────────────────────────────────────────────────────────

  /// Try [pin].
  Future<UnlockOutcome> unlockWithPin(String pin) async {
    if (isThrottled) return UnlockOutcome.throttled;

    if (await verifyStoredPin(_storedPin, pin)) {
      // A correct PIN is the moment to move an old record forward: the plaintext (or weakly
      // hashed) value is only recoverable here, where the user has just supplied it.
      if (pinNeedsRehash(_storedPin)) {
        final upgraded = await hashPinForStorage(pin);
        _storedPin = upgraded;
        await _repository.insertSetting('app_pin', upgraded);
      }
      await _clearThrottle();
      _locked = false;
      _safeNotify();
      return UnlockOutcome.unlocked;
    }

    _failedAttempts++;
    final lockout = pinLockoutAfterFailure(_failedAttempts, _now());
    if (lockout > 0) {
      _lockedUntilMs = lockout;
      // The counter resets with the lockout so the next window is a fresh five attempts rather
      // than one-strike-forever.
      _failedAttempts = 0;
    }
    // Persisted so force-stopping the app does not reset the throttle — otherwise the throttle is
    // worth nothing against anyone willing to swipe it away.
    await _persistThrottle();
    _safeNotify();
    return lockout > 0 ? UnlockOutcome.throttled : UnlockOutcome.wrongPin;
  }

  /// Try the platform biometric prompt.
  ///
  /// A failure is never a lockout: the PIN is the authority, and a fingerprint reader that cannot
  /// read a wet finger must not consume the user's attempts.
  Future<bool> unlockWithBiometrics() async {
    final prompt = biometricPrompt;
    if (prompt == null || !_useBiometrics || !isConfigured) return false;
    bool ok;
    try {
      ok = await prompt('Unlock OmniTerm');
    } catch (_) {
      return false;
    }
    if (!ok) return false;
    await _clearThrottle();
    _locked = false;
    _safeNotify();
    return true;
  }

  // ── privileged actions ──────────────────────────────────────────────────────
  //
  // Ported from `withSudoAuth` / `verifyPinForSensitiveAction` in `ui/AppViewModel.kt:2521`.

  /// True when a PIN is stored, whether or not the lock is currently enabled.
  bool get hasStoredPin => _storedPin != null && _storedPin!.isNotEmpty;

  /// Whether running an action with [sudoPassword] should be gated behind re-authentication.
  ///
  /// Kotlin's condition exactly: a **stored** sudo password plus some way to authenticate. The
  /// reasoning is that a saved sudo password turns "holding the unlocked phone" into "can reboot the
  /// server", so the password is not used until the person is re-identified. With no stored password
  /// there is nothing extra to protect — the user will be typing it — and with no PIN or biometrics
  /// there is nothing to check them against.
  ///
  /// Note this deliberately does **not** consult whether the app lock is currently *enabled*: the
  /// existence of a PIN is what makes the check possible, and Kotlin tests the same two things.
  bool requiresSudoAuth(String sudoPassword) =>
      sudoPassword.trim().isNotEmpty && (canUseBiometrics || hasStoredPin);

  /// Verifies a PIN for a privileged action **without unlocking the app**.
  ///
  /// Returns null when it matched, otherwise the message to show. Shares the lock screen's throttle
  /// on purpose: a separate allowance here would be a way to brute-force the same PIN at full speed
  /// from a different dialog.
  Future<String?> verifyPinForSensitiveAction(String pin) async {
    if (isThrottled) return 'Too many attempts — wait a moment';
    if (await verifyStoredPin(_storedPin, pin)) {
      if (pinNeedsRehash(_storedPin)) {
        final upgraded = await hashPinForStorage(pin);
        _storedPin = upgraded;
        await _repository.insertSetting('app_pin', upgraded);
      }
      await _clearThrottle();
      _safeNotify();
      return null;
    }

    _failedAttempts++;
    final lockout = pinLockoutAfterFailure(_failedAttempts, _now());
    if (lockout > 0) {
      _lockedUntilMs = lockout;
      _failedAttempts = 0;
    }
    await _persistThrottle();
    _safeNotify();
    return lockout > 0 ? 'Too many attempts — wait 30 seconds' : 'Incorrect PIN';
  }

  /// Runs the biometric prompt for a privileged action, without unlocking the app.
  ///
  /// A refusal is not a lockout, for the same reason it is not on the lock screen: the PIN is the
  /// authority, and a reader that cannot read a wet finger must not consume the user's attempts.
  Future<bool> authenticateForSensitiveAction() async {
    final prompt = biometricPrompt;
    if (prompt == null || !_useBiometrics) return false;
    try {
      return await prompt('Authenticate for sudo');
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearThrottle() async {
    _failedAttempts = 0;
    _lockedUntilMs = 0;
    await _persistThrottle();
  }

  /// Writes both halves of the throttle.
  ///
  /// **Both**, because they are one fact between them. Persisting only the attempt count left the
  /// deadline in memory, so a force-stop cleared the wait and the throttle rate-limited nothing —
  /// restart, try one PIN, restart, try another.
  Future<void> _persistThrottle() async {
    await _repository.insertSetting('pin_failed_attempts', '$_failedAttempts');
    await _repository.insertSetting('pin_locked_until', '$_lockedUntilMs');
  }

  // ── configuration ───────────────────────────────────────────────────────────

  /// Set (or change) the PIN and turn the lock on.
  Future<void> setPin(String pin) async {
    final stored = await hashPinForStorage(pin);
    _storedPin = stored;
    _enabled = true;
    await _repository.insertSetting('app_pin', stored);
    await _repository.insertSetting('app_lock_enabled', 'true');
    await _clearThrottle();
    _safeNotify();
  }

  /// Turn the lock off and forget the PIN.
  Future<void> clearPin() async {
    _storedPin = null;
    _enabled = false;
    _useBiometrics = false;
    _locked = false;
    await _repository.deleteSetting('app_pin');
    await _repository.insertSetting('app_lock_enabled', 'false');
    await _repository.insertSetting('biometrics_enabled', 'false');
    await _clearThrottle();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Milliseconds since this isolate started, from a clock the user cannot set.
///
/// Dart's [Stopwatch] is backed by the platform's monotonic clock, so it is immune to wall-clock
/// changes — but on Android that clock stops during deep sleep, which is why it is only ever used as
/// one half of the pair in [AppLockController.onForegrounded].
final Stopwatch _processElapsed = Stopwatch()..start();

int _processElapsedMs() => _processElapsed.elapsedMilliseconds;
