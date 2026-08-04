import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/health_tier_form.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/health_scoring_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Health Scoring tool, ported from `HealthScoringToolView` in `ui/ToolsScreen.kt`.
///
/// Twenty-four numbers that decide every host's score. The live preview exists because those
/// numbers are abstract on their own — "warn at 50" means nothing next to "a host at 60% CPU now
/// scores 95".
class HealthScoringScreen extends StatefulWidget {
  const HealthScoringScreen({super.key});

  @override
  State<HealthScoringScreen> createState() => _HealthScoringScreenState();
}

class _HealthScoringScreenState extends State<HealthScoringScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<HealthScoringViewModel>().start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HealthScoringViewModel>();
    final scheme = Theme.of(context).colorScheme;
    final error = vm.validationError;

    return Stack(
      children: [
        ListView(
          key: const ValueKey('healthScoring.list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            Text(
              'A host starts at 100. Each metric subtracts points once it reaches a tier, and the '
              'lowest score wins — so the worst thing wrong with a host is what its number reflects.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (vm.status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OmniCard(
                  key: const ValueKey('healthScoring.status'),
                  leftAccent: OmniColors.green,
                  child: Row(
                    children: [
                      Expanded(child: Text(vm.status!, style: const TextStyle(fontSize: 12))),
                      IconButton(
                        key: const ValueKey('healthScoring.status.dismiss'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: vm.dismissStatus,
                      ),
                    ],
                  ),
                ),
              ),
            _Preview(vm: vm),
            const SizedBox(height: 12),
            for (final metric in HealthMetric.values) _MetricCard(vm: vm, metric: metric),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  key: const ValueKey('healthScoring.error'),
                  style: const TextStyle(color: OmniColors.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            TextButton(
              key: const ValueKey('healthScoring.reset'),
              onPressed: () => _confirmReset(context, vm),
              child: const Text('Reset to defaults', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Row(
            children: [
              if (vm.isDirty)
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('healthScoring.revert'),
                    onPressed: vm.revert,
                    child: const Text('Discard changes'),
                  ),
                ),
              if (vm.isDirty) const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('healthScoring.save'),
                  onPressed: vm.canSave ? () => vm.save() : null,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmReset(BuildContext context, HealthScoringViewModel vm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('healthScoring.reset.dialog'),
        title: const Text('Reset scoring thresholds?'),
        content: const Text(
          'Every threshold and penalty goes back to the shipped defaults, and your tuning is lost.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('healthScoring.reset.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('healthScoring.reset.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await vm.resetToDefaults();
  }
}

/// A worked example, recomputed as the fields change.
class _Preview extends StatefulWidget {
  const _Preview({required this.vm});

  final HealthScoringViewModel vm;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  // A host under moderate load: high enough to cross a tier or two with the defaults, so the
  // preview actually demonstrates something rather than sitting at 100.
  double _cpu = 60;
  double _memory = 75;
  double _disk = 85;
  double _latency = 60;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final breakdown = widget.vm.previewFor(
      cpuPercent: _cpu,
      memoryPercent: _memory,
      diskPercent: _disk,
      latencyMs: _latency.round(),
    );

    return OmniCard(
      key: const ValueKey('healthScoring.preview'),
      leftAccent: OmniColors.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Worked example',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
              if (breakdown != null)
                Text(
                  '${breakdown.score}',
                  key: const ValueKey('healthScoring.preview.score'),
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    fontFamily: OmniFonts.mono,
                    color: breakdown.score >= 70
                        ? OmniColors.green
                        : breakdown.score >= 40
                        ? OmniColors.amber
                        : OmniColors.red,
                  ),
                ),
            ],
          ),
          for (final (label, value, max, onChanged)
              in <(String, double, double, ValueChanged<double>)>[
                ('CPU ${_cpu.round()}%', _cpu, 100, (v) => setState(() => _cpu = v)),
                ('Memory ${_memory.round()}%', _memory, 100, (v) => setState(() => _memory = v)),
                ('Disk ${_disk.round()}%', _disk, 100, (v) => setState(() => _disk = v)),
                (
                  'Latency ${_latency.round()} ms',
                  _latency,
                  500,
                  (v) => setState(() => _latency = v),
                ),
              ])
            Row(
              children: [
                SizedBox(width: 120, child: Text(label, style: const TextStyle(fontSize: 11))),
                Expanded(
                  child: Slider(
                    key: ValueKey('healthScoring.preview.${label.split(' ').first}'),
                    value: value,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          if (breakdown == null)
            Text(
              // Showing a score derived from half-typed thresholds would be worse than none.
              'Fix the values below to see the score.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            )
          else if (breakdown.factors.isEmpty)
            Text(
              'Nothing deducts at these readings.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            )
          else
            for (final factor in breakdown.factors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  '−${factor.penalty}  ${factor.label}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: OmniFonts.mono,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.vm, required this.metric});

  final HealthScoringViewModel vm;
  final HealthMetric metric;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fields = vm.draft[metric]!;
    final error = validateTier(fields, metric);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: OmniCard(
        key: ValueKey('healthScoring.metric.${metric.name}'),
        leftAccent: error == null ? OmniColors.amber : OmniColors.red,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(metric.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text(
              'Thresholds in ${metric.unit}, then the points each tier deducts.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (tier, read, write) in <(String, String, void Function(String))>[
                  ('Warn', fields.warnAt, (v) => fields.warnAt = v),
                  ('High', fields.highAt, (v) => fields.highAt = v),
                  ('Critical', fields.criticalAt, (v) => fields.criticalAt = v),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _NumberField(
                        fieldKey: 'healthScoring.${metric.name}.${tier.toLowerCase()}At',
                        label: tier,
                        initial: read,
                        onChanged: (value) => vm.edit(metric, (_) => write(value)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (tier, read, write) in <(String, String, void Function(String))>[
                  ('Warn', fields.warnPenalty, (v) => fields.warnPenalty = v),
                  ('High', fields.highPenalty, (v) => fields.highPenalty = v),
                  ('Critical', fields.criticalPenalty, (v) => fields.criticalPenalty = v),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _NumberField(
                        fieldKey: 'healthScoring.${metric.name}.${tier.toLowerCase()}Penalty',
                        label: '−$tier',
                        initial: read,
                        onChanged: (value) => vm.edit(metric, (_) => write(value)),
                      ),
                    ),
                  ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  error,
                  key: ValueKey('healthScoring.metric.${metric.name}.error'),
                  style: const TextStyle(color: OmniColors.red, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.fieldKey,
    required this.label,
    required this.initial,
    required this.onChanged,
  });

  final String fieldKey;
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    // Reverting or resetting replaces the draft wholesale, and the controller would otherwise keep
    // showing what the user had typed.
    if (widget.initial != old.initial && widget.initial != _controller.text) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: ValueKey(widget.fieldKey),
      controller: _controller,
      keyboardType: TextInputType.number,
      style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
      onChanged: widget.onChanged,
      decoration: omniInputDecoration(context, labelText: widget.label),
    );
  }
}
