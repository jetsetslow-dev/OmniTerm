import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Kotlin's `rememberCopyWithConfirmation`: puts [text] on the clipboard and says so.
///
/// The messenger is captured before the copy awaits, so a caller that closes its sheet straight
/// afterwards still gets the confirmation shown.
Future<void> copyWithConfirmation(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
}
