import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../view_model/app_lock_controller.dart';

/// Re-authentication before a privileged action uses a **stored** sudo password.
///
/// Ported from `SudoAuthDialog` in `ui/AppUi.kt:411` and the `withSudoAuth` gate it serves.
///
/// The threat it answers is specific: once a sudo password is saved against a host, anyone holding
/// the unlocked phone can reboot that server or stop its services. A "are you sure?" confirmation
/// does not address that — it asks about intent, not identity. This asks for the PIN or a biometric
/// before the stored password is used at all.
///
/// Returns true when the user authenticated, false when they cancelled or failed.
Future<bool> requestSudoAuth(
  BuildContext context,
  AppLockController controller, {

  /// What the user is being asked to confirm. Parameterised rather than duplicated: the prompt,
  /// the biometric path and the throttle are identical whatever the action, and a second copy of
  /// a security dialog is a second place for one of those to be got wrong.
  String title = 'Authenticate for sudo',
}) async {
  final result = await showDialog<bool>(
    context: context,
    // Not dismissible by tapping outside: this is a security prompt, and an accidental dismissal
    // that silently cancelled a reboot would read as the app ignoring the button.
    barrierDismissible: false,
    builder: (_) => _SudoAuthDialog(controller: controller, title: title),
  );
  return result ?? false;
}

class _SudoAuthDialog extends StatefulWidget {
  const _SudoAuthDialog({required this.controller, required this.title});

  final AppLockController controller;
  final String title;

  @override
  State<_SudoAuthDialog> createState() => _SudoAuthDialogState();
}

class _SudoAuthDialogState extends State<_SudoAuthDialog> {
  final TextEditingController _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Offered straight away when it is available, as Kotlin does — the PIN field stays underneath
    // for anyone who dismisses it or has no reader.
    if (widget.controller.canUseBiometrics) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometrics());
    }
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _tryBiometrics() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final ok = await widget.controller.authenticateForSensitiveAction();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    // Not an error: a cancelled or unreadable biometric is ordinary, and calling it a failure trains
    // the user to ignore the message that does matter.
    setState(() => _busy = false);
  }

  Future<void> _submitPin() async {
    if (_busy) return;
    setState(() => _busy = true);
    final failure = await widget.controller.verifyPinForSensitiveAction(_pin.text);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasPin = widget.controller.hasStoredPin;
    return AlertDialog(
      key: const ValueKey('sudoAuth.dialog'),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Confirm to run this privileged action with the stored sudo password.',
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          if (hasPin)
            TextField(
              key: const ValueKey('sudoAuth.pin'),
              controller: _pin,
              enabled: !_busy,
              autofocus: !widget.controller.canUseBiometrics,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'PIN'),
              onSubmitted: (_) => _submitPin(),
            )
          else
            Text(
              'Use your biometric prompt to continue.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _error!,
                key: const ValueKey('sudoAuth.error'),
                style: const TextStyle(color: OmniColors.red, fontSize: 12),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('sudoAuth.cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        if (hasPin)
          TextButton(
            key: const ValueKey('sudoAuth.confirm'),
            onPressed: _busy ? null : _submitPin,
            child: const Text('Confirm'),
          ),
      ],
    );
  }
}
