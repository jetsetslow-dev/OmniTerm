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
  }) : _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppRepository _repository;
  final BiometricPrompt? biometricPrompt;
  final int Function() _now;

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
    _failedAttempts =
        (int.tryParse(await _repository.getSetting('pin_failed_attempts') ?? '') ?? 0)
            .clamp(0, pinMaxAttempts);
    // A cold start is always locked when the lock is configured. Anything else would let a
    // force-stop — the easiest thing in the world to do to a phone you have picked up — be a way
    // straight past it.
    _locked = isConfigured;
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

  /// The app went to the background.
  ///
  /// [isChangingConfigurations] is Android's rotation/theme re-create, which is not the user
  /// leaving; starting the timer there would lock the app when someone turned their phone sideways.
  void onBackgrounded({bool isChangingConfigurations = false}) {
    if (!shouldRecordAppBackground(isChangingConfigurations: isChangingConfigurations)) return;
    // `??=`, not `=`. The platform sends `inactive` **again on the way back in**, immediately
    // before `resumed`, so assigning here reset the clock to "now" microseconds before it was read
    // — and the lock silently never engaged, no matter how long the app had been away. The first
    // transition out is the one that counts; `onForegrounded` clears it.
    _backgroundedAtMs ??= _now();
  }

  /// The app came back to the foreground; lock if it was away long enough.
  void onForegrounded() {
    final since = _backgroundedAtMs;
    _backgroundedAtMs = null;
    if (!isConfigured || _locked || since == null) return;
    // `>=` rather than `>`: a zero timeout means "lock immediately", and a strict comparison would
    // make the one setting that asks for the most protection the only one that never fires.
    if (_now() - since >= _timeoutMs) {
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
    await _repository.insertSetting('pin_failed_attempts', '$_failedAttempts');
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

  Future<void> _clearThrottle() async {
    _failedAttempts = 0;
    _lockedUntilMs = 0;
    await _repository.insertSetting('pin_failed_attempts', '0');
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
