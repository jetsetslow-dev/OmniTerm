import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/scripts_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/script_editor_dialog.dart';

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

    return ToolScaffold(
      title: 'Scripts',
      keyPrefix: 'scripts',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      onAdd: () => _openEditor(context, vm, forFleet: !isQuick),
      child: ShortViewportScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OmniTabRow(
              key: const ValueKey('scripts.tabs'),
              labels: const ['Quick scripts', 'Fleet commands'],
              selectedIndex: vm.activeTab.index,
              onSelected: (i) => vm.activeTab = ScriptsTab.values[i],
              tabKeys: [for (final tab in ScriptsTab.values) ValueKey('scripts.tab.${tab.name}')],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                isQuick
                    ? 'Quick scripts run on the currently selected host and can be filtered by OS or '
                          'platform.'
                    : 'Fleet commands are broadcast commands for multiple hosts or groups from the '
                          'Fleet screen.',
                style: composeBody(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _PresetToggle(vm: vm, fleet: !isQuick),
            ),
            const SizedBox(height: 8),
            Expanded(child: _ScriptGrid(vm: vm)),
          ],
        ),
      ),
    );
  }
}

/// Kotlin's add/edit wiring: a new Fleet command starts in the "Fleet" category, offered to Fleet.
Future<void> _openEditor(
  BuildContext context,
  ScriptsViewModel vm, {
  QuickScript? existing,
  bool forFleet = false,
}) {
  final categories = {
    for (final s in vm.allScripts) s.category.trim().isEmpty ? 'General' : s.category,
  }.toList()..sort();
  final addingFleet = existing == null && forFleet;
  return showScriptEditorDialog(
    context,
    vm,
    existing: existing,
    title: existing != null ? 'Edit script' : 'Add script',
    initialCategory: addingFleet ? 'Fleet' : 'General',
    defaultAvailableForQuick: !addingFleet,
    defaultAvailableForFleet: addingFleet,
    knownCategories: categories,
  );
}

class _PresetToggle extends StatelessWidget {
  const _PresetToggle({required this.vm, required this.fleet});

  final ScriptsViewModel vm;
  final bool fleet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = fleet ? vm.fleetPresetsEnabled : vm.homelabPresetsEnabled;
    final family = fleet ? 'fleet' : 'homelab';

    return OmniCard(
      inset: const EdgeInsets.all(12),
      key: ValueKey('scripts.presets.$family'),
      leftAccent: fleet ? OmniColors.cyan : OmniColors.purple,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fleet ? 'Fleet default commands' : 'Homelab preset scripts',
                  style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                Text(
                  fleet
                      ? 'CPU/RAM, disk, services, logs, containers, ports, and kernel presets for '
                            'broadcast use.'
                      : 'Proxmox, CasaOS, Home Assistant, Linux, and general ops snippets. Each '
                            'script remains editable.',
                  style: composeBody(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            key: ValueKey('scripts.presets.$family.switch'),
            value: enabled,
            onChanged: vm.busy ? null : (on) => _confirm(context, on),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(BuildContext context, bool on) async {
    final (title, message) = switch ((fleet, on)) {
      (false, true) => (
        'Enable preset scripts?',
        'This adds curated quick scripts for common homelab platforms, resetting any earlier '
            'edits to them. You can edit or delete them afterwards.',
      ),
      (false, false) => (
        'Disable preset scripts?',
        'This removes the curated preset scripts, including any edits to them. Your own scripts '
            'are kept.',
      ),
      (true, true) => (
        'Enable fleet defaults?',
        'This adds built-in fleet broadcast commands, resetting any earlier edits to them. You '
            'can edit or delete them afterwards.',
      ),
      (true, false) => (
        'Disable fleet defaults?',
        'This removes the built-in fleet commands, including edits to those defaults. Your own '
            'commands are kept.',
      ),
    };
    final confirmed = await showOmniConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: on ? 'Enable' : 'Disable',
      destructive: !on,
      keyPrefix: 'scripts.presets',
    );
    if (confirmed) await vm.setPresetsEnabled(fleet: fleet, enabled: on);
  }
}

/// Kotlin's two-column `LazyVerticalGrid`: a full-width cyan heading per category, then cards in
/// rows whose height is the taller card's.
class _ScriptGrid extends StatelessWidget {
  const _ScriptGrid({required this.vm});

  final ScriptsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final MapEntry(key: category, value: scripts) in vm.groupedScripts.entries) {
      rows.add(
        Padding(
          key: ValueKey('scripts.group.$category'),
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            category,
            style: composeBody(fontWeight: FontWeight.bold, fontSize: 14, color: OmniColors.cyan),
          ),
        ),
      );
      for (var i = 0; i < scripts.length; i += 2) {
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Expanded(
                  child: _ScriptCard(vm: vm, script: scripts[i]),
                ),
                Expanded(
                  child: i + 1 < scripts.length
                      ? _ScriptCard(vm: vm, script: scripts[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        );
      }
    }
    return ListView.separated(
      key: const ValueKey('scripts.list'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => rows[i],
    );
  }
}

class _ScriptCard extends StatelessWidget {
  const _ScriptCard({required this.vm, required this.script});

  final ScriptsViewModel vm;
  final QuickScript script;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).colorScheme.onSurfaceVariant;
    void edit() => _openEditor(context, vm, existing: script);

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 84),
      child: OmniCard(
        inset: const EdgeInsets.all(12),
        key: ValueKey('scripts.card.${script.id}'),
        onTap: edit,
        onLongPress: edit,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '${script.emoji} ${script.name}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: composeBody(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                _CompactIconAction(
                  key: ValueKey('scripts.card.${script.id}.edit'),
                  tooltip: 'Edit script',
                  icon: Icons.edit,
                  color: OmniColors.cyan,
                  onPressed: edit,
                ),
                _CompactIconAction(
                  key: ValueKey('scripts.card.${script.id}.delete'),
                  tooltip: 'Delete script',
                  icon: Icons.delete,
                  color: const Color(0xFFFF0000),
                  onPressed: () => _confirmDelete(context),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (script.availableForQuick)
                  const OmniTag(label: 'Quick', color: OmniColors.green),
                if (script.availableForFleet) const OmniTag(label: 'Fleet', color: OmniColors.cyan),
                if (script.targetOs.toLowerCase() != 'any')
                  OmniTag(label: script.targetOs, color: OmniColors.amber),
                if (script.targetSystem.toLowerCase() != 'any')
                  OmniTag(label: script.targetSystem, color: OmniColors.purple),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              script.command,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: composeBody(fontSize: 10, color: meta, fontFamily: OmniFonts.mono),
            ),
            if (script.notes.trim().isNotEmpty)
              Text(
                script.notes,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: composeBody(fontSize: 10, color: meta, fontStyle: FontStyle.italic),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showOmniConfirm(
      context,
      title: 'Delete script?',
      message: 'Delete quick script "${script.name}"?',
      confirmLabel: 'Delete',
      destructive: true,
      keyPrefix: 'scripts.delete',
    );
    if (confirmed) await vm.deleteScript(script);
  }
}

/// Kotlin's 24dp icon button (`Modifier.size(24.dp)`) holding a 16dp icon.
class _CompactIconAction extends StatelessWidget {
  const _CompactIconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: 16,
      onPressed: onPressed,
      icon: Icon(icon, color: color),
    ),
  );
}
