import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../theme/colors.dart';
import '../view_model/app_lock_controller.dart';

/// The check before anything runs with sudo on [hostName]: reboot, service control, Read with
/// sudo, SFTP sudo mode and every install. Ported from `SudoAuthDialog` in `ui/AppUi.kt`.
///
/// Every one asks, every time, saved sudo password or not: whoever holds the unlocked phone should
/// not be able to run anything as root on a server without saying so. What it asks for:
/// - App Lock on: its biometrics or PIN.
/// - otherwise the phone's own lock (fingerprint, face, or its PIN, pattern or password).
/// - with no screen lock at all, a plain "Run this with sudo on host?" with Cancel and Continue.
///
/// Returns true when the action may run, false when the user cancelled.
Future<bool> requestSudoAuth(
  BuildContext context,
  AppLockController lock, {
  required String hostName,
}) async {
  final l10n = AppLocalizations.of(context);
  final question = l10n.runThisWithSudoOn(hostName);
  if (lock.sudoAuthUsesAppLock) {
    return _requestAppLockAuth(
      context,
      lock,
      title: l10n.authenticateForSudo,
      reason: 'Authenticate for sudo',
      message: question,
      // Keep system operations modal so an accidental outside tap does not silently cancel a
      // reboot or other requested action.
      dismissible: false,
    );
  }
  final deviceLock = await lock.hasDeviceLock();
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => deviceLock
        ? _DeviceLockDialog(lock: lock, title: l10n.authenticateForSudo, question: question)
        : _PlainSudoDialog(question: question),
  );
  return result ?? false;
}

/// Saving settings while a PIN exists asks for it first, matching Kotlin (`ui/ToolsScreen.kt`):
/// otherwise anyone holding a briefly-unlocked phone could turn the app lock off.
Future<bool> requestSettingsAuth(BuildContext context, AppLockController lock) =>
    _requestAppLockAuth(
      context,
      lock,
      title: 'Authenticate to save',
      reason: 'Authenticate to save settings',
      message: 'Enter your app PIN to apply these changes.',
      // Settings follows Kotlin's dismissible confirmation.
      dismissible: true,
    );

Future<bool> _requestAppLockAuth(
  BuildContext context,
  AppLockController lock, {
  required String title,
  required String reason,
  required String message,
  required bool dismissible,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: dismissible,
    builder: (_) => _AppLockAuthDialog(
      controller: lock,
      title: title,
      reason: reason,
      message: message,
      autofocusPin: !dismissible,
    ),
  );
  return result ?? false;
}

/// App Lock's PIN, with its biometric prompt offered straight away when it is on.
///
/// The threat it answers is specific: anyone holding the unlocked phone could otherwise reboot a
/// server or stop its services. A "are you sure?" confirmation asks about intent, not identity;
/// this asks for the PIN or a biometric.
class _AppLockAuthDialog extends StatefulWidget {
  const _AppLockAuthDialog({
    required this.controller,
    required this.title,
    required this.reason,
    required this.message,
    required this.autofocusPin,
  });

  final AppLockController controller;
  final String title;

  /// What the biometric prompt says it is for.
  final String reason;
  final String message;
  final bool autofocusPin;

  @override
  State<_AppLockAuthDialog> createState() => _AppLockAuthDialogState();
}

class _AppLockAuthDialogState extends State<_AppLockAuthDialog> {
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
    final ok = await widget.controller.authenticateForSensitiveAction(reason: widget.reason);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = widget.controller.biometricError;
    });
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
    return AlertDialog(
      key: const ValueKey('sudoAuth.dialog'),
      // Scrollable because the content is a multi-child Column with no scroll of its own: on a
      // small phone in landscape at 200% text it does not fit, and an AlertDialog clips rather
      // than scrolls unless it is asked to. Same shape as parity defects 112 and 113.
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('sudoAuth.pin'),
            controller: _pin,
            enabled: !_busy,
            autofocus: widget.autofocusPin && !widget.controller.canUseBiometrics,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submitPin(),
          ),
          if (_busy) const LinearProgressIndicator(),
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
        TextButton(
          key: const ValueKey('sudoAuth.confirm'),
          onPressed: _busy ? null : _submitPin,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

/// The phone's own lock, asked for as soon as the dialog shows. Backing out of the system prompt
/// leaves this dialog up, to ask again with Unlock or to cancel.
class _DeviceLockDialog extends StatefulWidget {
  const _DeviceLockDialog({required this.lock, required this.title, required this.question});

  final AppLockController lock;
  final String title;
  final String question;

  @override
  State<_DeviceLockDialog> createState() => _DeviceLockDialogState();
}

class _DeviceLockDialogState extends State<_DeviceLockDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  Future<void> _ask() async {
    if (!mounted) return;
    final ok = await widget.lock.authenticateWithDeviceLock(widget.title, widget.question);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const ValueKey('sudoAuth.device'),
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.question, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Text(
            l10n.useYourScreenLockToContinue,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('sudoAuth.cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const ValueKey('sudoAuth.unlock'),
          onPressed: _ask,
          child: Text(l10n.unlock),
        ),
      ],
    );
  }
}

/// No App Lock and no screen lock: there is nothing to check identity against, so it asks plainly
/// rather than running silently or refusing.
class _PlainSudoDialog extends StatelessWidget {
  const _PlainSudoDialog({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const ValueKey('sudoAuth.plain'),
      scrollable: true,
      title: Text(question),
      content: Text(l10n.sudoAsksWithoutAScreenLock, style: const TextStyle(fontSize: 14)),
      actions: [
        TextButton(
          key: const ValueKey('sudoAuth.cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const ValueKey('sudo.confirm.continue'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.continueLabel),
        ),
      ],
    );
  }
}
