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
}) async =>
    await _showConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: destructive,
      keyPrefix: keyPrefix,
    ) !=
    null;

/// Kotlin's `askWithOption`: [showOmniConfirm] with an unticked checkbox labelled [optionLabel]
/// under the message. Null when cancelled; otherwise whether the box was ticked.
Future<bool?> showOmniConfirmWithOption(
  BuildContext context, {
  required String title,
  required String message,
  required String optionLabel,
  String confirmLabel = 'Confirm',
  bool destructive = true,
  String keyPrefix = 'confirm',
}) => _showConfirm(
  context,
  title: title,
  message: message,
  confirmLabel: confirmLabel,
  destructive: destructive,
  keyPrefix: keyPrefix,
  optionLabel: optionLabel,
);

/// Null when cancelled; otherwise the option's state, false when there is none.
Future<bool?> _showConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required bool destructive,
  required String keyPrefix,
  String? optionLabel,
}) => showDialog<bool>(
  context: context,
  builder: (_) => _OmniConfirmDialog(
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    destructive: destructive,
    keyPrefix: keyPrefix,
    optionLabel: optionLabel,
  ),
);

class _OmniConfirmDialog extends StatefulWidget {
  const _OmniConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.destructive,
    required this.keyPrefix,
    this.optionLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;
  final String keyPrefix;
  final String? optionLabel;

  @override
  State<_OmniConfirmDialog> createState() => _OmniConfirmDialogState();
}

class _OmniConfirmDialogState extends State<_OmniConfirmDialog> {
  bool _option = false;

  @override
  Widget build(BuildContext context) {
    final option = widget.optionLabel;
    return AlertDialog(
      key: ValueKey('${widget.keyPrefix}.dialog'),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: option == null
            ? Text(widget.message)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.message),
                  const SizedBox(height: 8),
                  OmniOptionRow(
                    key: ValueKey('${widget.keyPrefix}.option'),
                    label: option,
                    value: _option,
                    onChanged: (value) => setState(() => _option = value),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: ValueKey('${widget.keyPrefix}.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ValueKey('${widget.keyPrefix}.confirm'),
          onPressed: () => Navigator.of(context).pop(_option),
          child: Text(
            widget.confirmLabel,
            style: TextStyle(
              color: widget.destructive ? OmniColors.red : Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// A checkbox and its label as one control: the whole row toggles, as Kotlin's `toggleable` rows
/// do. Disabled when [onChanged] is null.
class OmniOptionRow extends StatelessWidget {
  const OmniOptionRow({super.key, required this.label, required this.value, this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: onChanged == null ? null : (checked) => onChanged(checked ?? false),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}
