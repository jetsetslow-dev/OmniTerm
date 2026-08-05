import 'package:flutter/material.dart';

import '../../../domain/cron_schedule.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/monitor_view_model.dart';
import '../../widgets/omni_components.dart';

/// Monitor → CRON, ported from `CronMonitorTab` in `ui/MonitorScreen.kt`.
///
/// Shows the host user's crontab, and edits it through a schedule dialog rather than as text. The
/// thing to keep in mind reading this: **there is no partial write.** Every change here re-installs
/// the entire crontab, so every line the parse produced — comments, `MAILTO=`, entries this app does
/// not understand — is carried along untouched.
class CronTab extends StatefulWidget {
  const CronTab({super.key, required this.vm});

  final MonitorViewModel vm;

  @override
  State<CronTab> createState() => _CronTabState();
}

class _CronTabState extends State<CronTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.vm.loadCron();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (vm.cronLoading) const LinearProgressIndicator(minHeight: 2),
        Row(
          children: [
            Expanded(
              child: Text(
                'Scheduled jobs for ${vm.monitoredServer?.username ?? 'this host'}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            IconButton(
              key: const ValueKey('cron.reload'),
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: vm.cronLoading ? null : vm.loadCron,
            ),
            TextButton.icon(
              key: const ValueKey('cron.add'),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add', style: TextStyle(fontSize: 12)),
              // Nothing to add to until a crontab has actually been read: writing one now would
              // replace a file nobody has seen.
              onPressed: vm.cronReadable && !vm.cronLoading ? () => _edit(context, vm, null) : null,
            ),
          ],
        ),
        if (vm.cronStatus != null)
          OmniCard(
            key: const ValueKey('cron.status'),
            leftAccent: vm.cronStatus == 'Crontab saved.' ? OmniColors.green : OmniColors.amber,
            child: Row(
              children: [
                Expanded(child: Text(vm.cronStatus!, style: const TextStyle(fontSize: 12))),
                IconButton(
                  key: const ValueKey('cron.status.dismiss'),
                  icon: const Icon(Icons.close, size: 14),
                  onPressed: vm.dismissCronStatus,
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Expanded(child: _body(context, vm, scheme)),
      ],
    );
  }

  Widget _body(BuildContext context, MonitorViewModel vm, ColorScheme scheme) {
    // A crontab that could not be read is not an empty crontab, and the difference decides whether
    // it is safe to write one. The reason comes from the host, verbatim.
    if (!vm.cronReadable) {
      if (vm.cronLoading) return const SizedBox.shrink();
      return Center(
        key: const ValueKey('cron.unreadable'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_clock, size: 32, color: OmniColors.textMuted),
              const SizedBox(height: 8),
              Text(
                'This host would not show its crontab, so nothing here can be changed.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              if (vm.cronError != null) ...[
                const SizedBox(height: 8),
                SelectionArea(
                  child: Text(
                    vm.cronError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (vm.cronLines.isEmpty) {
      return Center(
        key: const ValueKey('cron.empty'),
        child: Text(
          'No scheduled jobs for this user.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.separated(
      key: const ValueKey('cron.list'),
      itemCount: vm.cronLines.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) => _CronCard(vm: vm, line: vm.cronLines[index]),
    );
  }
}

class _CronCard extends StatelessWidget {
  const _CronCard({required this.vm, required this.line});

  final MonitorViewModel vm;
  final CronLine line;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final comment = line.raw.startsWith('#');

    return OmniCard(
      key: ValueKey('cron.line.${line.index}'),
      leftAccent: line.editable ? OmniColors.amber : OmniColors.textMuted,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.editable
                      ? (line.label.isEmpty ? cronSummary(line.expression) : line.label)
                      // Said plainly, because the alternative is a row that looks broken. A line
                      // this app does not understand is still the user's line and still runs.
                      : 'Kept as written',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  line.editable ? line.command : line.raw,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: OmniFonts.mono,
                    color: comment ? OmniColors.textMuted : scheme.onSurfaceVariant,
                  ),
                ),
                if (line.editable)
                  Text(
                    line.label.isEmpty
                        ? line.expression
                        : '${line.expression}  ·  ${cronSummary(line.expression)}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: OmniFonts.mono,
                      color: OmniColors.amber,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('cron.line.${line.index}.edit'),
            tooltip: 'Edit',
            icon: const Icon(Icons.edit, size: 16),
            onPressed: line.editable ? () => _edit(context, vm, line) : null,
          ),
          IconButton(
            key: ValueKey('cron.line.${line.index}.delete'),
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, size: 16, color: OmniColors.red),
            onPressed: () => _confirmDelete(context, vm, line),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmDelete(BuildContext context, MonitorViewModel vm, CronLine line) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('cron.delete.dialog'),
      title: const Text('Delete this scheduled job?'),
      // Says what actually happens, not what it looks like: the whole crontab is rewritten, which
      // is worth knowing before agreeing to it.
      content: Text(
        'This rewrites the crontab for ${vm.monitoredServer?.username ?? 'this user'} without '
        'the line:\n\n${line.raw}',
        style: const TextStyle(fontSize: 12),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cron.delete.cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('cron.delete.confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );

  if (confirmed ?? false) {
    await vm.saveCron(vm.cronLines.where((l) => l.index != line.index).toList());
  }
}

/// Opens the schedule editor for [existing], or for a new entry when it is null.
Future<void> _edit(BuildContext context, MonitorViewModel vm, CronLine? existing) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _ScheduleDialog(initial: existing),
  );
  if (result == null) return;

  final next = [
    for (final line in vm.cronLines)
      if (existing != null && line.index == existing.index)
        CronLine(
          index: line.index,
          raw: result,
          expression: '',
          command: '',
          label: '',
          editable: true,
        )
      else
        line,
    if (existing == null)
      CronLine(
        index: 1 << 30,
        raw: result,
        expression: '',
        command: '',
        label: '',
        editable: true,
      ),
  ];
  await vm.saveCron(next);
}

class _ScheduleDialog extends StatefulWidget {
  const _ScheduleDialog({this.initial});

  final CronLine? initial;

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late final _label = TextEditingController(text: widget.initial?.label ?? '');
  late final _command = TextEditingController(text: widget.initial?.command ?? '');
  late final List<TextEditingController> _parts;
  late String _preset;

  static const _fields = [
    ('Minute', '0-59, * or */5', 0, 59),
    ('Hour', '0-23, * or */2', 0, 23),
    ('Day', '1-31 or *', 1, 31),
    ('Month', '1-12 or *', 1, 12),
    ('Weekday', '0-7, Sunday is 0 or 7', 0, 7),
  ];

  @override
  void initState() {
    super.initState();
    final expression = widget.initial?.expression ?? cronPresets['daily']!;
    // A shorthand has no five fields to show, so the editor starts from the equivalent it can
    // express and the user sees exactly what will be written.
    final source = cronShorthands.containsKey(expression) ? cronPresets['daily']! : expression;
    final values = source.split(RegExp(r'\s+'));
    _parts = [
      for (var i = 0; i < 5; i++)
        TextEditingController(text: i < values.length ? values[i] : '*'),
    ];
    _preset = cronPresetFor(source);
  }

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    for (final c in _parts) {
      c.dispose();
    }
    super.dispose();
  }

  String get _expression => _parts.map((c) => c.text.trim()).join(' ');

  bool get _valid => _command.text.trim().isNotEmpty && isCronExpressionValid(_expression);

  void _applyPreset(String preset) {
    final values = cronPresets[preset]!.split(' ');
    for (var i = 0; i < 5; i++) {
      _parts[i].text = values[i];
    }
    setState(() => _preset = preset);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      key: const ValueKey('cron.editor'),
      title: Text(widget.initial == null ? 'Add scheduled job' : 'Edit scheduled job'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                children: [
                  for (final preset in [...cronPresets.keys, 'custom'])
                    ChoiceChip(
                      key: ValueKey('cron.preset.$preset'),
                      label: Text(preset, style: const TextStyle(fontSize: 11)),
                      selected: _preset == preset,
                      // "Custom" is not a schedule, so selecting it changes nothing: it is what the
                      // chips show once the fields stop matching a preset.
                      onSelected: preset == 'custom' ? null : (_) => _applyPreset(preset),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              for (final (index, field) in _fields.indexed) ...[
                TextField(
                  key: ValueKey('cron.field.${field.$1.toLowerCase()}'),
                  controller: _parts[index],
                  decoration: InputDecoration(
                    labelText: field.$1,
                    hintText: field.$2,
                    isDense: true,
                    errorText: isCronPartValid(_parts[index].text, field.$3, field.$4)
                        ? null
                        : 'Not a ${field.$1.toLowerCase()} cron accepts',
                  ),
                  style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                  onChanged: (_) => setState(() => _preset = cronPresetFor(_expression)),
                ),
                const SizedBox(height: 6),
              ],
              const SizedBox(height: 4),
              Text(
                cronSummary(_expression),
                key: const ValueKey('cron.editor.summary'),
                style: const TextStyle(fontSize: 12, color: OmniColors.amber),
              ),
              Text(
                _expression,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: OmniFonts.mono,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('cron.editor.label'),
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  isDense: true,
                  helperText: 'Stored as a comment on the line',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('cron.editor.command'),
                controller: _command,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Command', isDense: true),
                style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cron.editor.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('cron.editor.save'),
          onPressed: _valid
              ? () => Navigator.of(context).pop(
                  cronLineFor(
                    expression: _expression,
                    command: _command.text,
                    label: _label.text,
                  ),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
