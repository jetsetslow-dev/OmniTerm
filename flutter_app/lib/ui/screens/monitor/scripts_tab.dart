import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/command_danger.dart';
import '../../../domain/script_filters.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/monitor_view_model.dart';
import '../../view_model/scripts_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/run_command_dialog.dart';

/// Monitor → Quick scripts, ported from `QuickScriptsMonitorTab` in `ui/MonitorScreen.kt`.
///
/// The saved quick scripts, narrowed to the ones that apply to **this** host, plus a field for a
/// one-off command. This is where `quickScriptMatchesHost` finally does something: the targeting
/// columns have round-tripped through the editor since the Tools port with nothing consuming them,
/// so a Proxmox helper was offered on a Raspberry Pi.
class ScriptsTab extends StatefulWidget {
  const ScriptsTab({super.key, required this.vm});

  final MonitorViewModel vm;

  @override
  State<ScriptsTab> createState() => _ScriptsTabState();
}

class _ScriptsTabState extends State<ScriptsTab> {
  final _custom = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ScriptsViewModel>().start();
    });
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final server = vm.monitoredServer;
    final scheme = Theme.of(context).colorScheme;
    final scripts = context.watch<ScriptsViewModel>().allScripts;

    // The metrics the poller holds for *this* host, which is what the targeting reads. Null until
    // the first sample lands, and a script that names an OS does not match a host that has not said
    // what it is — so the list starts short and grows, which is why the note below exists.
    final metrics = vm.metricsSampledAt == null ? null : vm.metrics;
    final matching = scripts.where((s) => quickScriptMatchesHost(s, metrics)).toList()
      ..sort((a, b) {
        final byCategory = a.category.compareTo(b.category);
        if (byCategory != 0) return byCategory;
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final grouped = <String, List<QuickScript>>{};
    for (final script in matching) {
      grouped
          .putIfAbsent(script.category.trim().isEmpty ? 'General' : script.category, () => [])
          .add(script);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(
            key: const ValueKey('monitor.scripts'),
            children: [
              OmniCard(
                key: const ValueKey('monitor.scripts.custom'),
                leftAccent: OmniColors.green,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ONE-OFF COMMAND',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('monitor.scripts.command'),
                      controller: _custom,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        prefixText: '\$ ',
                        hintText: 'A command to run on this host',
                        isDense: true,
                      ),
                      style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        key: const ValueKey('monitor.scripts.run'),
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Run'),
                        onPressed: _custom.text.trim().isEmpty || server == null
                            ? null
                            : () => _run(context, vm, 'Custom command', _custom.text.trim()),
                      ),
                    ),
                  ],
                ),
              ),
              if (metrics == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    // Said out loud, because otherwise a short list looks like the final answer and
                    // the user goes looking for scripts they are sure they saved.
                    'This host has not reported its OS yet, so scripts that target one are hidden. '
                    'They appear after the first telemetry sample.',
                    key: const ValueKey('monitor.scripts.unfiltered'),
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              if (matching.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    scripts.isEmpty
                        ? 'No quick scripts saved yet. Tools → Quick Scripts is where they live.'
                        : 'None of your quick scripts target this host.',
                    key: const ValueKey('monitor.scripts.empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              for (final entry in grouped.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Text(
                    entry.key,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: OmniColors.cyan,
                    ),
                  ),
                ),
                for (final script in entry.value)
                  _ScriptCard(
                    script: script,
                    server: server,
                    onRun: () =>
                        _run(context, vm, '${script.emoji} ${script.name}'.trim(), script.command),
                  ),
              ],
            ],
          ),
        ),
        if (vm.scriptRun != null) _RunPanel(vm: vm),
      ],
    );
  }

  Future<void> _run(BuildContext context, MonitorViewModel vm, String title, String command) async {
    final server = vm.monitoredServer;
    if (server == null) return;

    // The same guard Fleet uses, for the same reason: one tap on a card must not be enough to run
    // an arbitrary command on someone's server.
    final hits = commandDangerHits(command);
    final confirmed = await confirmRunCommand(
      context,
      command: command,
      targets: [server],
      danger: hits.isEmpty ? null : 'This command looks destructive (${hits.join(', ')}).',
    );
    if (confirmed) await vm.runScript(title, command);
  }
}

class _ScriptCard extends StatelessWidget {
  const _ScriptCard({required this.script, required this.server, required this.onRun});

  final QuickScript script;
  final Server? server;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final targeted = script.targetOs.toLowerCase() != 'any' && script.targetOs.trim().isNotEmpty;
    final system =
        script.targetSystem.toLowerCase() != 'any' && script.targetSystem.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: OmniCard(
        key: ValueKey('monitor.script.${script.id}'),
        leftAccent: server == null
            ? OmniColors.textMuted
            : OmniColors.serverAccent(server!.serverColor, server!.name),
        onTap: server == null ? null : onRun,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${script.emoji} ${script.name}'.trim(),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    script.command,
                    maxLines: 3,
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Why this script is here rather than filtered out — visible so a list that
                // changes between hosts is explicable.
                if (targeted) OmniTag(label: script.targetOs, color: OmniColors.amber),
                if (system) OmniTag(label: script.targetSystem, color: OmniColors.purple),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the running command has printed so far.
class _RunPanel extends StatelessWidget {
  const _RunPanel({required this.vm});

  final MonitorViewModel vm;

  @override
  Widget build(BuildContext context) {
    final run = vm.scriptRun!;
    final scheme = Theme.of(context).colorScheme;
    final text = run.output.toString();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: OmniCard(
        key: const ValueKey('monitor.scripts.output'),
        leftAccent: run.error != null ? OmniColors.red : OmniColors.cyan,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (!run.finished)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Expanded(
                  child: Text(
                    run.title,
                    key: const ValueKey('monitor.scripts.output.title'),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
                IconButton(
                  key: const ValueKey('monitor.scripts.output.close'),
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: vm.clearScriptRun,
                ),
              ],
            ),
            if (run.error != null)
              Text(
                run.error!,
                key: const ValueKey('monitor.scripts.output.error'),
                style: const TextStyle(fontSize: 11, color: OmniColors.red),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: SelectionArea(
                  child: Text(
                    // A command that printed nothing is a fact worth stating: silence and "still
                    // starting up" look identical otherwise.
                    text.trim().isEmpty && run.finished && run.error == null ? '(no output)' : text,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: OmniFonts.mono,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
