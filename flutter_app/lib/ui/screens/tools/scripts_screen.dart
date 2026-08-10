import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../../domain/script_filters.dart';
import '../../view_model/scripts_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Scripts tool, ported from `QuickScriptsToolView` in `ui/ToolsScreen.kt`.
///
/// Two lists over one table: **Quick scripts** run on the selected host, **Fleet commands** are
/// broadcast from the Fleet screen. A script can be offered in either or both.
class ScriptsScreen extends StatefulWidget {
  const ScriptsScreen({super.key});

  @override
  State<ScriptsScreen> createState() => _ScriptsScreenState();
}

class _ScriptsScreenState extends State<ScriptsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ScriptsViewModel>().start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ScriptsViewModel>();
    final scheme = Theme.of(context).colorScheme;
    final isQuick = vm.activeTab == ScriptsTab.quick;
    final grouped = vm.groupedScripts;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              // Scrollable, as the SFTP and Infra tab strips are. "Quick scripts" and "Fleet
              // commands" do not fit a phone at 200% text, and a tab the user cannot reach is a
              // screen they cannot open. Safe as a scroll view here — unlike Fleet's summary bar,
              // this row has no `Spacer` needing a bounded width.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final tab in ScriptsTab.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('scripts.tab.${tab.name}'),
                          label: Text(
                            tab == ScriptsTab.quick ? 'Quick scripts' : 'Fleet commands',
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: vm.activeTab == tab,
                          onSelected: (_) => vm.activeTab = tab,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                // Saying what each list is for, because "quick" and "fleet" do not explain the
                // difference on their own.
                isQuick
                    ? 'Quick scripts run on the currently selected host and can be filtered by OS '
                          'or platform.'
                    : 'Fleet commands are broadcast to several hosts or groups from the Fleet '
                          'screen.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _PresetToggle(vm: vm, fleet: !isQuick),
            ),
            if (vm.status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: OmniCard(
                  key: const ValueKey('scripts.status'),
                  leftAccent: OmniColors.green,
                  child: Row(
                    children: [
                      Expanded(child: Text(vm.status!, style: const TextStyle(fontSize: 12))),
                      IconButton(
                        tooltip: 'Dismiss',
                        key: const ValueKey('scripts.status.dismiss'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: vm.dismissStatus,
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: grouped.isEmpty
                  ? Center(
                      key: const ValueKey('scripts.empty'),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          isQuick
                              ? 'No quick scripts yet. Add one, or turn on the homelab presets '
                                    'above.'
                              : 'No fleet commands yet. Add one, or turn on the default commands '
                                    'above.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView(
                      key: const ValueKey('scripts.list'),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 88),
                      children: [
                        for (final entry in grouped.entries) ...[
                          SectionHeader(title: entry.key),
                          // Order is the user's, not the database's: the row someone runs daily
                          // belongs at the top of its category, and `sortOrder` has been stored and
                          // honoured since the port with nothing able to change it.
                          ReorderableListView(
                            key: ValueKey('scripts.group.${entry.key}'),
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            // The whole card opens the editor on tap, so a full-card drag handle
                            // would fight that gesture and swallow the list's own scroll. The grip
                            // on the right is the only thing that starts a drag.
                            buildDefaultDragHandles: false,
                            onReorderItem: (oldIndex, newIndex) =>
                                vm.reorderCategory(entry.key, oldIndex, newIndex),
                            children: [
                              for (final (index, script) in entry.value.indexed)
                                _ScriptCard(
                                  key: ValueKey('scripts.row.${script.id}'),
                                  vm: vm,
                                  script: script,
                                  dragIndex: index,
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            key: const ValueKey('scripts.add'),
            tooltip: isQuick ? 'New quick script' : 'New fleet command',
            onPressed: () => showScriptEditorSheet(context, vm, forFleet: !isQuick),
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class _PresetToggle extends StatelessWidget {
  const _PresetToggle({required this.vm, required this.fleet});

  final ScriptsViewModel vm;
  final bool fleet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = fleet ? vm.fleetPresetsEnabled : vm.homelabPresetsEnabled;

    return OmniCard(
      key: ValueKey('scripts.presets.${fleet ? 'fleet' : 'homelab'}'),
      leftAccent: fleet ? OmniColors.cyan : OmniColors.purple,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fleet ? 'Fleet default commands' : 'Homelab preset scripts',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                Text(
                  fleet
                      ? 'CPU, RAM, disk, services, logs, containers, ports, kernel.'
                      : 'Proxmox, CasaOS, Home Assistant, Linux and general homelab.',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            key: ValueKey('scripts.presets.${fleet ? 'fleet' : 'homelab'}.switch'),
            value: enabled,
            onChanged: vm.busy ? null : (on) => _confirm(context, vm, fleet: fleet, on: on),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(
    BuildContext context,
    ScriptsViewModel vm, {
    required bool fleet,
    required bool on,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('scripts.presets.dialog'),
        title: Text(on ? 'Enable preset scripts?' : 'Disable preset scripts?'),
        content: Text(
          on
              // Enabling re-seeds, so it silently reverts edits unless that is said out loud.
              ? 'This adds the curated scripts and resets any edits you made to them. You can '
                    'change or delete them afterwards.'
              : 'This removes the curated scripts, including any edits to them. Your own scripts '
                    'are kept.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('scripts.presets.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('scripts.presets.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              on ? 'Enable' : 'Disable',
              style: TextStyle(color: on ? null : OmniColors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await vm.setPresetsEnabled(fleet: fleet, enabled: on);
    }
  }
}

class _ScriptCard extends StatelessWidget {
  const _ScriptCard({super.key, required this.vm, required this.script, required this.dragIndex});

  final ScriptsViewModel vm;
  final QuickScript script;

  /// Position within its category, which is what the drag handle reorders.
  final int dragIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('scripts.card.${script.id}'),
        leftAccent: OmniColors.named(script.color),
        onTap: () => showScriptEditorSheet(context, vm, existing: script),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                script.emoji,
                style: const TextStyle(
                  fontFamily: OmniFonts.mono,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          script.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ),
                      if (vm.isPristinePresetScript(script)) ...[
                        const SizedBox(width: 6),
                        // Marked so it is obvious that turning the family off takes it away — and
                        // that editing it makes it permanently yours.
                        const OmniTag(label: 'PRESET', color: OmniColors.textMuted),
                      ],
                      // Why this script will not appear on some hosts, said here rather than only
                      // inside the editor.
                      if (script.targetOs.isNotEmpty && script.targetOs.toLowerCase() != 'any') ...[
                        const SizedBox(width: 6),
                        OmniTag(label: script.targetOs, color: OmniColors.amber),
                      ],
                      if (script.targetSystem.isNotEmpty &&
                          script.targetSystem.toLowerCase() != 'any') ...[
                        const SizedBox(width: 6),
                        OmniTag(label: script.targetSystem, color: OmniColors.purple),
                      ],
                    ],
                  ),
                  Text(
                    script.command,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: OmniFonts.mono,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('scripts.card.${script.id}.delete'),
              tooltip: 'Delete script',
              icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
              onPressed: () => _confirmDelete(context, vm, script),
            ),
            ReorderableDragStartListener(
              key: ValueKey('scripts.card.${script.id}.drag'),
              index: dragIndex,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_handle, size: 18, color: OmniColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmDelete(BuildContext context, ScriptsViewModel vm, QuickScript script) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('scripts.delete.dialog'),
      title: Text('Delete "${script.name}"?'),
      content: Text(
        vm.isPristinePresetScript(script)
            // A preset is recoverable, which is worth saying — it changes whether this needs care.
            ? 'This is a preset script; you can bring it back with the toggle above.'
            : 'This script is deleted permanently.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('scripts.delete.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('scripts.delete.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.deleteScript(script);
}

Future<void> showScriptEditorSheet(
  BuildContext context,
  ScriptsViewModel vm, {
  QuickScript? existing,
  bool forFleet = false,
  String? initialCommand,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ScriptEditorSheet(
      vm: vm,
      existing: existing,
      forFleet: forFleet,
      initialCommand: initialCommand,
    ),
  );
}

class ScriptEditorSheet extends StatefulWidget {
  const ScriptEditorSheet({
    super.key,
    required this.vm,
    this.existing,
    this.forFleet = false,
    this.initialCommand,
  });

  final ScriptsViewModel vm;
  final QuickScript? existing;
  final bool forFleet;
  final String? initialCommand;

  @override
  State<ScriptEditorSheet> createState() => _ScriptEditorSheetState();
}

class _ScriptEditorSheetState extends State<ScriptEditorSheet> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _command = TextEditingController(
    text: widget.existing?.command ?? widget.initialCommand ?? '',
  );
  late final _emoji = TextEditingController(text: widget.existing?.emoji ?? '');
  late final _category = TextEditingController(text: widget.existing?.category ?? 'General');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');

  late String _color = widget.existing?.color ?? 'cyan';
  late String _targetOs = widget.existing?.targetOs ?? 'Any';
  late String _targetSystem = widget.existing?.targetSystem ?? 'Any';
  late bool _quick = widget.existing?.availableForQuick ?? !widget.forFleet;
  late bool _fleet = widget.existing?.availableForFleet ?? widget.forFleet;
  late bool _longRunning = widget.existing?.longRunning ?? false;
  String? _failure;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _emoji.dispose();
    _category.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final failure = await widget.vm.saveScript(
      existing: widget.existing,
      name: _name.text,
      command: _command.text,
      emoji: _emoji.text,
      color: _color,
      category: _category.text,
      notes: _notes.text,
      longRunning: _longRunning,
      availableForQuick: _quick,
      availableForFleet: _fleet,
      targetOs: _targetOs,
      targetSystem: _targetSystem,
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _failure = failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final editingPreset = existing != null && widget.vm.isPristinePresetScript(existing);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.existing == null ? 'New script' : 'Edit script',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close editor',
                    key: const ValueKey('scripts.editor.close'),
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: const ValueKey('scripts.editor.form'),
                padding: const EdgeInsets.all(16),
                children: [
                  if (editingPreset)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        // The toggle re-seeds, so an edit is undone by turning presets off and on.
                        'Editing a preset makes it yours — but re-enabling the preset family will '
                        'overwrite it again.',
                        key: const ValueKey('scripts.editor.presetNote'),
                        style: const TextStyle(fontSize: 11, color: OmniColors.amber),
                      ),
                    ),
                  TextField(
                    key: const ValueKey('scripts.editor.name'),
                    controller: _name,
                    decoration: omniInputDecoration(context, labelText: 'Name'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('scripts.editor.command'),
                    controller: _command,
                    maxLines: 6,
                    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                    decoration: omniInputDecoration(context, labelText: 'Command'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('scripts.editor.emoji'),
                          controller: _emoji,
                          decoration: omniInputDecoration(context, labelText: 'Badge'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          key: const ValueKey('scripts.editor.category'),
                          controller: _category,
                          decoration: omniInputDecoration(context, labelText: 'Category'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('scripts.editor.color'),
                    initialValue: _color,
                    decoration: omniInputDecoration(context, labelText: 'Colour'),
                    items: [
                      for (final name in const [
                        'cyan',
                        'green',
                        'amber',
                        'red',
                        'purple',
                        'orange',
                      ])
                        DropdownMenuItem(value: name, child: Text(name)),
                    ],
                    onChanged: (v) => setState(() => _color = v ?? 'cyan'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('scripts.editor.notes'),
                    controller: _notes,
                    maxLines: 2,
                    decoration: omniInputDecoration(
                      context,
                      labelText: 'Notes',
                      hintText: 'What this does, and anything to watch out for',
                    ),
                  ),
                  const SizedBox(height: 12),
                  // What decides where this script is offered. Monitor's Quick scripts tab reads
                  // these columns; until now they could only be set by a preset or a restore, so a
                  // script written by hand was offered on every host whatever it was for.
                  DropdownButtonFormField<String>(
                    key: const ValueKey('scripts.editor.targetOs'),
                    initialValue: quickScriptOsOptions.contains(_targetOs) ? _targetOs : 'Any',
                    decoration: omniInputDecoration(
                      context,
                      labelText: 'Runs on',
                      helperText: 'Hidden on hosts that report a different OS',
                    ),
                    items: [
                      for (final os in quickScriptOsOptions)
                        DropdownMenuItem(value: os, child: Text(os)),
                    ],
                    onChanged: (v) => setState(() => _targetOs = v ?? 'Any'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('scripts.editor.targetSystem'),
                    initialValue: quickScriptSystemOptions.contains(_targetSystem)
                        ? _targetSystem
                        : 'Any',
                    decoration: omniInputDecoration(
                      context,
                      labelText: 'Platform',
                      helperText: 'Hidden unless the host reports this platform',
                    ),
                    items: [
                      for (final system in quickScriptSystemOptions)
                        DropdownMenuItem(value: system, child: Text(system)),
                    ],
                    onChanged: (v) => setState(() => _targetSystem = v ?? 'Any'),
                  ),
                  SwitchListTile(
                    key: const ValueKey('scripts.editor.quick'),
                    title: const Text('Offer in Quick scripts'),
                    subtitle: const Text('Runs on the selected host'),
                    value: _quick,
                    onChanged: (v) => setState(() => _quick = v),
                  ),
                  SwitchListTile(
                    key: const ValueKey('scripts.editor.fleet'),
                    title: const Text('Offer in Fleet commands'),
                    subtitle: const Text('Broadcast to several hosts at once'),
                    value: _fleet,
                    onChanged: (v) => setState(() => _fleet = v),
                  ),
                  SwitchListTile(
                    key: const ValueKey('scripts.editor.longRunning'),
                    title: const Text('Long running'),
                    // Streams output rather than waiting for the command to finish.
                    subtitle: const Text('Stream output instead of waiting for it to finish'),
                    value: _longRunning,
                    onChanged: (v) => setState(() => _longRunning = v),
                  ),
                ],
              ),
            ),
            if (_failure != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _failure!,
                    key: const ValueKey('scripts.editor.error'),
                    style: const TextStyle(color: OmniColors.red, fontSize: 12),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('scripts.editor.save'),
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
