import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Kotlin's `ConfirmHost`: an AlertDialog with a plain title, a plain message, Cancel, and a
/// confirm button in primary — or red when the action is destructive.
Future<bool> showOmniConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
  String keyPrefix = 'confirm',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: ValueKey('$keyPrefix.dialog'),
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          key: ValueKey('$keyPrefix.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ValueKey('$keyPrefix.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            confirmLabel,
            style: TextStyle(
              color: destructive ? OmniColors.red : Theme.of(dialogContext).colorScheme.primary,
            ),
          ),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
