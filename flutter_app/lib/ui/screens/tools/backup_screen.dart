import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/backup_selection.dart';
import '../../theme/colors.dart';
import '../../view_model/backup_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Backup tool, ported from `BackupToolView` in `ui/ToolsScreen.kt`.
///
/// Exporting produces the file's text and hands it to the caller; importing takes text back. Where
/// the file lives is a platform concern, so this screen deliberately does not own it.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<BackupViewModel>();
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      key: const ValueKey('backup.list'),
      padding: const EdgeInsets.all(12),
      children: [
        if (vm.status != null || vm.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OmniCard(
              key: const ValueKey('backup.message'),
              leftAccent: vm.error != null ? OmniColors.red : OmniColors.green,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vm.error ?? vm.status!,
                      style: TextStyle(
                        fontSize: 12,
                        color: vm.error != null ? OmniColors.red : null,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('backup.message.dismiss'),
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: vm.dismissMessages,
                  ),
                ],
              ),
            ),
          ),
        const SectionHeader(title: 'What to include'),
        Row(
          children: [
            TextButton(
              key: const ValueKey('backup.selectAll'),
              onPressed: vm.selectAll,
              child: const Text('All', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: const ValueKey('backup.selectNone'),
              onPressed: vm.selectNone,
              child: const Text('None', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        for (final section in BackupSection.values)
          CheckboxListTile(
            key: ValueKey('backup.section.${section.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(section.label, style: const TextStyle(fontSize: 13)),
            subtitle: _dependencyNote(section, scheme),
            value: vm.selection.contains(section),
            onChanged: (value) =>
                vm.toggleSection(section, enabled: value ?? false),
          ),
        const SizedBox(height: 8),
        if (vm.requiresPassphrase)
          Text(
            // Saying *why* rather than just demanding it: a passphrase prompt with no explanation
            // reads as an obstacle, and this one is protecting stored passwords and private keys.
            'This selection contains credentials and host details, so the file will be encrypted '
            'with a passphrase. There is no way to recover the backup without it.',
            key: const ValueKey('backup.sensitiveNote'),
            style: const TextStyle(fontSize: 11, color: OmniColors.amber),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('backup.export'),
          icon: const Icon(Icons.upload_file, size: 18),
          label: Text(vm.busy ? 'Working…' : 'Create backup'),
          onPressed: vm.canExport ? () => _export(context, vm) : null,
        ),
        const SizedBox(height: 24),
        const SectionHeader(title: 'Restore'),
        Text(
          // The two things a user needs to know before tapping: nothing is destroyed, and the
          // passphrase is not recoverable.
          'Restoring adds the backup\'s contents alongside what is already here — nothing is '
          'deleted or overwritten. An encrypted backup needs the passphrase it was made with.',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('backup.import'),
          icon: const Icon(Icons.restore, size: 18),
          label: const Text('Restore from backup'),
          onPressed: vm.busy ? null : () => _import(context, vm),
        ),
      ],
    );
  }

  Widget? _dependencyNote(BackupSection section, ColorScheme scheme) {
    final dependencies = BackupSelection.dependenciesOf(section);
    if (dependencies.isEmpty) return null;
    // Explaining the coupling before the checkbox moves on its own, which would otherwise look
    // like the app second-guessing the user.
    return Text(
      'Includes ${dependencies.map((d) => d.label.toLowerCase()).join(' and ')}',
      style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
    );
  }

  Future<void> _export(BuildContext context, BackupViewModel vm) async {
    var passphrase = '';
    if (vm.requiresPassphrase) {
      final entered = await _askPassphrase(
        context,
        title: 'Choose a passphrase',
        confirmLabel: 'Create backup',
        // Stated at the point of decision, where it can still change what the user does.
        note: 'Without this passphrase the backup cannot be opened. Nobody can reset it.',
      );
      if (entered == null) return;
      passphrase = entered;
    }

    final contents = await vm.exportBackup(passphrase);
    if (contents == null || !context.mounted) return;

    // Handing the text to the caller: writing it to a file is the platform's job (§18).
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('backup.export.result'),
        title: const Text('Backup created'),
        content: Text(
          '${vm.suggestedFileName()}\n\n${contents.length} characters. Saving it to a file is not '
          'wired up in this build yet.',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(
            key: const ValueKey('backup.export.result.close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context, BackupViewModel vm) async {
    final contents = await _askText(
      context,
      title: 'Paste a backup',
      hint: 'The contents of an .omnibak file',
    );
    if (contents == null || contents.trim().isEmpty || !context.mounted) return;

    var passphrase = '';
    if (BackupViewModel.looksEncrypted(contents)) {
      final entered = await _askPassphrase(
        context,
        title: 'Passphrase',
        confirmLabel: 'Restore',
        note: 'The passphrase this backup was created with.',
      );
      if (entered == null) return;
      passphrase = entered;
    }

    await vm.importBackup(contents, passphrase);
  }
}

Future<String?> _askPassphrase(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String note,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        dialogKey: 'backup.passphrase',
        title: title,
        note: note,
        confirmLabel: confirmLabel,
        obscure: true,
      ),
    );

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String hint,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _PromptDialog(
        dialogKey: 'backup.text',
        title: title,
        hint: hint,
        confirmLabel: 'Continue',
        multiline: true,
      ),
    );

/// Asks for one value. Owns its controller so it dies with the dialog.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.dialogKey,
    required this.title,
    required this.confirmLabel,
    this.note,
    this.hint,
    this.obscure = false,
    this.multiline = false,
  });

  final String dialogKey;
  final String title;
  final String confirmLabel;
  final String? note;
  final String? hint;
  final bool obscure;
  final bool multiline;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: ValueKey('${widget.dialogKey}.dialog'),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.note != null) ...[
            Text(widget.note!, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 10),
          ],
          TextField(
            key: ValueKey('${widget.dialogKey}.field'),
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscure,
            maxLines: widget.multiline ? 6 : 1,
            decoration: omniInputDecoration(context, hintText: widget.hint),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: ValueKey('${widget.dialogKey}.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ValueKey('${widget.dialogKey}.confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
