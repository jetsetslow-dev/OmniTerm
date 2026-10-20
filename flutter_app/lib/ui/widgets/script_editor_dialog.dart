import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/app_database.dart';
import '../../domain/script_filters.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/scripts_view_model.dart';
import 'omni_components.dart';
import 'omni_confirm.dart';

/// Opens Kotlin's `SharedScriptEditorDialog` (`ui/ScriptEditorDialog.kt`).
///
/// One dialog serves the Scripts tool (add/edit), Monitor's "Save script" and Fleet's "Save
/// command". An edit keeps the row's colour, long-running flag and order; a new script is cyan,
/// not long running, as Kotlin's `addQuickScript` callers pass.
Future<void> showScriptEditorDialog(
  BuildContext context,
  ScriptsViewModel vm, {
  QuickScript? existing,
  required String title,
  String initialCommand = '',
  String initialCategory = 'General',
  bool defaultAvailableForQuick = true,
  bool defaultAvailableForFleet = false,
  String defaultTargetOs = 'Any',
  List<String> knownCategories = const [],
}) => showDialog<void>(
  context: context,
  // Outside taps go through the dirty check rather than closing the dialog outright.
  barrierDismissible: false,
  builder: (_) => ScriptEditorDialog(
    vm: vm,
    existing: existing,
    title: title,
    initialCommand: initialCommand,
    initialCategory: initialCategory,
    defaultAvailableForQuick: defaultAvailableForQuick,
    defaultAvailableForFleet: defaultAvailableForFleet,
    defaultTargetOs: defaultTargetOs,
    knownCategories: knownCategories,
  ),
);

String _orAny(String? value) => (value == null || value.trim().isEmpty) ? 'Any' : value;

class ScriptEditorDialog extends StatefulWidget {
  const ScriptEditorDialog({
    super.key,
    required this.vm,
    required this.title,
    this.existing,
    this.initialCommand = '',
    this.initialCategory = 'General',
    this.defaultAvailableForQuick = true,
    this.defaultAvailableForFleet = false,
    this.defaultTargetOs = 'Any',
    this.knownCategories = const [],
  });

  final ScriptsViewModel vm;
  final String title;
  final QuickScript? existing;
  final String initialCommand;
  final String initialCategory;
  final bool defaultAvailableForQuick;
  final bool defaultAvailableForFleet;
  final String defaultTargetOs;
  final List<String> knownCategories;

  @override
  State<ScriptEditorDialog> createState() => _ScriptEditorDialogState();
}

class _ScriptEditorDialogState extends State<ScriptEditorDialog> {
  late final String _ogEmoji = widget.existing?.emoji ?? 'CMD';
  late final String _ogName = widget.existing?.name ?? '';
  late final String _ogCommand = widget.existing?.command ?? widget.initialCommand;
  late final String _ogCategory = widget.existing == null
      ? (widget.initialCategory.trim().isEmpty ? 'General' : widget.initialCategory)
      : (widget.existing!.category.trim().isEmpty ? 'General' : widget.existing!.category);
  late final bool _ogQuick = widget.existing?.availableForQuick ?? widget.defaultAvailableForQuick;
  late final bool _ogFleet = widget.existing?.availableForFleet ?? widget.defaultAvailableForFleet;
  late final String _ogOs = widget.existing != null
      ? _orAny(widget.existing!.targetOs)
      : _orAny(widget.defaultTargetOs);
  late final String _ogSystem = _orAny(widget.existing?.targetSystem);
  late final String _ogNotes = widget.existing?.notes ?? '';

  late final _emoji = TextEditingController(text: _ogEmoji);
  late final _name = TextEditingController(text: _ogName);
  late final _command = TextEditingController(text: _ogCommand);
  late final _category = TextEditingController(text: _ogCategory);
  late final _targetOs = TextEditingController(text: _ogOs);
  late final _targetSystem = TextEditingController(text: _ogSystem);
  late final _notes = TextEditingController(text: _ogNotes);
  late bool _quick = _ogQuick;
  late bool _fleet = _ogFleet;
  bool _saving = false;
  String? _failure;

  List<TextEditingController> get _controllers => [
    _emoji,
    _name,
    _command,
    _category,
    _targetOs,
    _targetSystem,
    _notes,
  ];

  @override
  void initState() {
    super.initState();
    for (final c in _controllers) {
      c.addListener(_rebuild);
    }
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    for (final c in _controllers) {
      c
        ..removeListener(_rebuild)
        ..dispose();
    }
    super.dispose();
  }

  bool get _dirty =>
      _name.text != _ogName ||
      _emoji.text != _ogEmoji ||
      _command.text != _ogCommand ||
      _category.text != _ogCategory ||
      _quick != _ogQuick ||
      _fleet != _ogFleet ||
      _targetOs.text != _ogOs ||
      _targetSystem.text != _ogSystem ||
      _notes.text != _ogNotes;

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _command.text.trim().isNotEmpty && (_quick || _fleet);

  Future<void> _attemptDismiss() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showOmniConfirm(
        context,
        title: 'Discard changes?',
        message: 'You have unsaved edits to this script. Discard them?',
        confirmLabel: 'Discard',
        destructive: true,
        keyPrefix: 'scripts.editor.discard',
      );
      if (!discard || !mounted) return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving || !_canSave) return;
    setState(() {
      _saving = true;
      _failure = null;
    });
    final existing = widget.existing;
    final category = _category.text.trim().isEmpty ? 'General' : _category.text.trim();
    String? failure;
    try {
      failure = await widget.vm.saveScript(
        existing: existing,
        emoji: _emoji.text.trim().isEmpty ? 'CMD' : _emoji.text,
        name: _name.text.trim(),
        command: _command.text.trim(),
        category: category,
        availableForQuick: _quick,
        availableForFleet: _fleet,
        targetOs: _orAny(_targetOs.text),
        targetSystem: _orAny(_targetSystem.text),
        notes: _notes.text.trim(),
        color: existing?.color ?? 'cyan',
        longRunning: existing?.longRunning ?? false,
      );
    } catch (_) {
      failure = 'Could not save the script. Check storage and try again.';
    }
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _failure = failure;
      });
    }
  }

  Widget _pickerField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String tooltip,
    required List<String> options,
    bool enabled = true,
  }) => TextField(
    key: key,
    controller: controller,
    enabled: enabled,
    decoration: omniInputDecoration(
      context,
      labelText: label,
      suffixIcon: PopupMenuButton<String>(
        key: ValueKey('${(key as ValueKey<String>).value}.menu'),
        tooltip: tooltip,
        enabled: enabled && options.isNotEmpty,
        icon: const Icon(Icons.arrow_drop_down),
        onSelected: (value) => controller.text = value,
        itemBuilder: (_) => [
          for (final option in options) PopupMenuItem(value: option, child: Text(option)),
        ],
      ),
    ),
  );

  Widget _checkbox(Key key, String label, bool value, ValueChanged<bool> onChanged) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Checkbox(key: key, value: value, onChanged: (v) => onChanged(v ?? false)),
      Text(label),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _attemptDismiss();
      },
      child: AlertDialog(
        key: const ValueKey('scripts.editor'),
        scrollable: true,
        title: Text(widget.title),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            TextField(
              key: const ValueKey('scripts.editor.emoji'),
              controller: _emoji,
              inputFormatters: [_ShortcutLabelFormatter()],
              decoration: omniInputDecoration(context, labelText: 'Shortcut label'),
            ),
            TextField(
              key: const ValueKey('scripts.editor.name'),
              controller: _name,
              decoration: omniInputDecoration(context, labelText: 'Script name'),
            ),
            TextField(
              key: const ValueKey('scripts.editor.command'),
              controller: _command,
              minLines: 2,
              maxLines: null,
              decoration: omniInputDecoration(context, labelText: 'Command'),
            ),
            _pickerField(
              key: const ValueKey('scripts.editor.category'),
              controller: _category,
              label: 'Category / group',
              tooltip: 'Pick existing category',
              options: widget.knownCategories,
            ),
            Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _checkbox(
                  const ValueKey('scripts.editor.quick'),
                  'Quick',
                  _quick,
                  (v) => setState(() => _quick = v),
                ),
                _checkbox(
                  const ValueKey('scripts.editor.fleet'),
                  'Fleet',
                  _fleet,
                  (v) => setState(() => _fleet = v),
                ),
              ],
            ),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: _pickerField(
                    key: const ValueKey('scripts.editor.targetOs'),
                    controller: _targetOs,
                    label: 'Quick OS',
                    tooltip: 'Pick OS',
                    options: quickScriptOsOptions,
                    enabled: _quick,
                  ),
                ),
                Expanded(
                  child: _pickerField(
                    key: const ValueKey('scripts.editor.targetSystem'),
                    controller: _targetSystem,
                    label: 'Quick system',
                    tooltip: 'Pick system',
                    options: quickScriptSystemOptions,
                    enabled: _quick,
                  ),
                ),
              ],
            ),
            TextField(
              key: const ValueKey('scripts.editor.notes'),
              controller: _notes,
              minLines: 2,
              maxLines: null,
              decoration: omniInputDecoration(
                context,
                labelText: 'Notes (optional)',
                hintText: 'What this script does, caveats, etc.',
              ),
            ),
            if (_failure != null)
              Text(
                _failure!,
                key: const ValueKey('scripts.editor.error'),
                style: composeDialogBody(color: OmniColors.red, fontSize: 12),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('scripts.editor.cancel'),
            onPressed: _saving ? null : _attemptDismiss,
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('scripts.editor.save'),
            onPressed: _canSave && !_saving ? _save : null,
            child: Text(widget.existing != null ? 'Save changes' : 'Save'),
          ),
        ],
      ),
    );
  }
}

/// Kotlin's `it.take(6).uppercase()` on the shortcut label (six UTF-16 units, as Kotlin counts).
class _ShortcutLabelFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    final text = (raw.length > 6 ? raw.substring(0, 6) : raw).toUpperCase();
    if (text == newValue.text) return newValue;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
