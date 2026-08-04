import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/app_lock_controller.dart';

/// Wraps the app with the lock screen and drives the background timer.
///
/// Ported from the app-lock handling in `MainActivity` + `AppUi.kt`. Mounted above everything so
/// there is no route, tab or dialog that can be reached around it — a gate with a way past it is
/// decoration.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // `inactive` covers the app switcher and a notification shade pull — moments where the
      // screen's contents are visible to someone holding the phone but the app has not truly gone
      // away. `paused` is a real backgrounding. Both start the timer; only the timeout decides.
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        widget.controller.onBackgrounded();
      case AppLifecycleState.resumed:
        widget.controller.onForegrounded();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, child) {
          if (!widget.controller.isLocked) return child!;
          // The app stays built underneath rather than being torn down, so unlocking returns the
          // user to exactly where they were — including a live terminal session.
          return Stack(
            children: [
              // Excluded from semantics as well as hidden: a screen reader must not be able to walk
              // the host list while the app is locked.
              ExcludeSemantics(child: ExcludeFocus(child: child!)),
              AppLockScreen(controller: widget.controller),
            ],
          );
        },
        child: widget.child,
      );
}

/// The unlock screen.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.controller});

  final AppLockController controller;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final TextEditingController _pin = TextEditingController();
  String? _message;
  bool _busy = false;
  Timer? _throttleTick;

  @override
  void initState() {
    super.initState();
    // Offered immediately rather than behind a button: the whole point of enabling biometrics is
    // not having to type. The PIN field stays available underneath if it fails or is dismissed.
    if (widget.controller.canUseBiometrics) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometrics());
    }
  }

  @override
  void dispose() {
    _throttleTick?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _tryBiometrics() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final ok = await widget.controller.unlockWithBiometrics();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Deliberately not an error: a failed or cancelled biometric read is ordinary, and calling it
      // a failure trains the user to ignore the message that matters.
      if (!ok) _message = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final pin = _pin.text;
    if (pin.isEmpty) return;
    setState(() => _busy = true);
    final outcome = await widget.controller.unlockWithPin(pin);
    if (!mounted) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _message = switch (outcome) {
        UnlockOutcome.unlocked => null,
        UnlockOutcome.wrongPin => 'Incorrect PIN — try again',
        UnlockOutcome.throttled => 'Too many attempts — wait 30 seconds',
      };
    });
    if (outcome == UnlockOutcome.throttled) _startThrottleTick();
  }

  /// Repaints once a second so the countdown moves rather than sitting at a stale number.
  void _startThrottleTick() {
    _throttleTick?.cancel();
    _throttleTick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !widget.controller.isThrottled) {
        timer.cancel();
        if (mounted) setState(() => _message = null);
        return;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final throttled = controller.isThrottled;
    final seconds = (controller.throttleRemainingMs / 1000).ceil();

    return Material(
      key: const ValueKey('lock.screen'),
      color: OmniColors.bg0,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 44, color: OmniColors.cyan),
                const SizedBox(height: 14),
                const Text(
                  'OmniTerm is locked',
                  style: TextStyle(
                    fontFamily: OmniFonts.display,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: OmniColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: 220,
                  child: TextField(
                    key: const ValueKey('lock.pin'),
                    controller: _pin,
                    autofocus: !controller.canUseBiometrics,
                    // `obscureText` alone still exposes the PIN to autofill and keyboard learning;
                    // a numeric keyboard with suggestions off is the rest of it.
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: 12,
                    enabled: !throttled && !_busy,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: OmniFonts.mono, letterSpacing: 6),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: controller.pinLength != null
                          ? '${controller.pinLength} digits'
                          : 'PIN',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  key: const ValueKey('lock.submit'),
                  onPressed: throttled || _busy ? null : _submit,
                  child: const Text('Unlock'),
                ),
                if (controller.canUseBiometrics) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('lock.biometrics'),
                    onPressed: _busy ? null : _tryBiometrics,
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('Use biometrics'),
                  ),
                ],
                if (throttled)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Too many attempts — try again in ${seconds}s',
                      key: const ValueKey('lock.throttled'),
                      style: const TextStyle(fontSize: 12, color: OmniColors.amber),
                    ),
                  )
                else if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _message!,
                      key: const ValueKey('lock.error'),
                      style: const TextStyle(fontSize: 12, color: OmniColors.red),
                    ),
                  ),
                const SizedBox(height: 18),
                Text(
                  // No "forgot your PIN?" escape: there is nothing this screen could offer that an
                  // attacker holding the phone could not also use. Recovery is a reinstall, and
                  // saying so is more honest than a dead-end link.
                  'There is no PIN recovery. Reinstalling clears the app and its saved hosts.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: OmniColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
