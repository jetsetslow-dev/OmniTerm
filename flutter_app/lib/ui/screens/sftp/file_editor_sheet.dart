import 'package:flutter/material.dart';

import '../../../data/remote_models.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/sftp_view_model.dart';

/// The remote text editor, ported from the Files editor in `ui/SftpScreen.kt`.
///
/// **It opens read-only, and a pencil unlocks it.** That is the Kotlin's behaviour and it is worth
/// keeping: most visits to a config file on a server are to *read* it, and an editor that is armed
/// by default turns a stray tap on a phone into an edit to `/etc/ssh/sshd_config`. Save is gated on
/// edit mode for the same reason.
Future<void> openFileEditor(BuildContext context, SftpViewModel vm, SftpFile entry) async {
  final contents = await vm.readForEditing(entry);
  // A failure has already put its reason on the screen; opening an empty editor over it would hide
  // the explanation behind a blank page.
  if (contents == null || !context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _FileEditorSheet(vm: vm, entry: entry, initial: contents),
  );
}

class _FileEditorSheet extends StatefulWidget {
  const _FileEditorSheet({required this.vm, required this.entry, required this.initial});

  final SftpViewModel vm;
  final SftpFile entry;
  final String initial;

  @override
  State<_FileEditorSheet> createState() => _FileEditorSheetState();
}

class _FileEditorSheetState extends State<_FileEditorSheet> {
  late final TextEditingController _text = TextEditingController(text: widget.initial);
  bool _editing = false;
  bool _saving = false;
  String? _failure;

  bool get _dirty => _text.text != widget.initial;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failure = null;
    });
    final result = await widget.vm.saveText(widget.entry, _text.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _failure = result.isError ? result.message : null;
    });
    // Only a save that is confirmed — or one that at least did not fail — closes. A mismatch keeps
    // the editor open *with the edits in it*, because the alternative is losing someone's work to a
    // save that silently did not happen.
    if (result.canClose && mounted) Navigator.of(context).pop();
  }

  Future<void> _close() async {
    if (_dirty && _editing) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('fileEditor.discard.dialog'),
          title: const Text('Discard changes?'),
          content: Text('Your edits to "${widget.entry.name}" have not been saved.'),
          actions: [
            TextButton(
              key: const ValueKey('fileEditor.discard.cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              key: const ValueKey('fileEditor.discard.confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Discard', style: TextStyle(color: OmniColors.red)),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.entry.name,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          // Saying which mode it is in, because the difference is the whole
                          // safety of the screen.
                          _editing ? 'Editing' : 'Read-only — tap the pencil to edit',
                          key: const ValueKey('fileEditor.mode'),
                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('fileEditor.editToggle'),
                    tooltip: _editing ? 'Stop editing' : 'Edit this file',
                    icon: Icon(
                      _editing ? Icons.lock_open : Icons.edit,
                      color: _editing ? OmniColors.amber : OmniColors.cyan,
                    ),
                    onPressed: _saving ? null : () => setState(() => _editing = !_editing),
                  ),
                  IconButton(
                    key: const ValueKey('fileEditor.close'),
                    icon: const Icon(Icons.close),
                    onPressed: _saving ? null : _close,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  key: const ValueKey('fileEditor.text'),
                  controller: _text,
                  // Read-only rather than disabled: the text stays selectable and copyable, which
                  // is most of why anyone opens a file on a server in the first place.
                  readOnly: !_editing,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    filled: true,
                    fillColor: scheme.surfaceContainer,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            if (_failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _failure!,
                  key: const ValueKey('fileEditor.error'),
                  style: const TextStyle(color: OmniColors.red, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('fileEditor.save'),
                  // Gated on edit mode *and* on there being something to save: a Save that writes
                  // the file back unchanged still rewrites its mtime, which is a real edit to
                  // anything watching the file.
                  onPressed: _editing && _dirty && !_saving ? _save : null,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
