import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../domain/tmux_session_name.dart';
import '../../../l10n/app_localizations.dart';
import '../../theme/colors.dart';
import '../../view_model/shell_view_model.dart';

/// Removes a saved tmux session, as Kotlin's `SavedSessionRemovalDialog`: Forget drops it from this
/// device only, End session stops it on its server first. A failed End keeps the dialog open with
/// the reason, so a server that no longer answers can still be cleared with Forget.
Future<void> showSavedSessionRemovalDialog(
  BuildContext context,
  ShellViewModel vm,
  PersistentSession row,
) => showDialog<void>(
  context: context,
  builder: (_) => _SavedSessionRemovalDialog(vm: vm, row: row),
);

class _SavedSessionRemovalDialog extends StatefulWidget {
  const _SavedSessionRemovalDialog({required this.vm, required this.row});

  final ShellViewModel vm;
  final PersistentSession row;

  @override
  State<_SavedSessionRemovalDialog> createState() => _SavedSessionRemovalDialogState();
}

class _SavedSessionRemovalDialogState extends State<_SavedSessionRemovalDialog> {
  bool _ending = false;
  String? _error;

  Future<void> _end() async {
    setState(() {
      _ending = true;
      _error = null;
    });
    final error = await widget.vm.endSavedSession(widget.row);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _ending = false;
        _error = error;
      });
    }
  }

  void _forget() {
    Navigator.of(context).pop();
    widget.vm.forgetResumable(widget.row);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _error;
    return PopScope(
      canPop: !_ending,
      child: AlertDialog(
        key: const ValueKey('shell.saved.remove.dialog'),
        scrollable: true,
        title: Text(l10n.removeSavedSession),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              l10n.forgetRemovesItFromThisDeviceOnly(
                displayTmuxSessionName(widget.row.tmuxName),
                widget.row.serverName,
              ),
            ),
            if (error != null)
              Text(
                error,
                key: const ValueKey('shell.saved.remove.error'),
                style: const TextStyle(color: OmniColors.red, fontSize: 13),
              ),
            if (_ending) const LinearProgressIndicator(),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('shell.saved.remove.cancel'),
            onPressed: _ending ? null : () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const ValueKey('shell.saved.remove.forget'),
            onPressed: _ending ? null : _forget,
            child: Text(l10n.forget),
          ),
          TextButton(
            key: const ValueKey('shell.saved.remove.end'),
            onPressed: _ending ? null : _end,
            child: Text(
              l10n.endSession,
              style: _ending ? null : const TextStyle(color: OmniColors.red),
            ),
          ),
        ],
      ),
    );
  }
}
