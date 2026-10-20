import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../domain/health_tier_form.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/health_scoring_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/popup_scroll_behavior.dart';

/// The Health scoring tool, ported from `HealthScoringToolView` and `HealthScoringCard` in
/// `ui/ToolsScreen.kt`: one card of twenty-four fields deciding every host's score.
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
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return ToolScaffold(
      title: 'Health scoring',
      keyPrefix: 'healthScoring',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      child: ScrollConfiguration(
        behavior: const PopupScrollBehavior(popupsOnly: false),
        child: SingleChildScrollView(
          key: const ValueKey('healthScoring.list'),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: OmniCard(
            leftAccent: OmniColors.amber,
            inset: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                Text('Health scoring', style: composeBody(fontWeight: FontWeight.bold)),
                Text(
                  'Score starts at 100; each metric subtracts points when it reaches a tier '
                  '(warn / high / critical). Edit the thresholds and the points each deducts.',
                  style: composeBody(fontSize: 11, color: muted),
                ),
                for (final metric in HealthMetric.values) ..._block(vm, metric),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      key: const ValueKey('healthScoring.save'),
                      onPressed: vm.canSave ? () => _confirmSave(context, vm) : null,
                      child: const Text('Save scoring'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('healthScoring.reset'),
                      onPressed: () => _confirmReset(context, vm),
                      child: const Text('Reset defaults'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _block(HealthScoringViewModel vm, HealthMetric metric) {
    final fields = vm.draft[metric]!;
    final errors = TierErrors(fields, metric);
    Widget field(
      String suffix,
      String label,
      String value,
      String? error,
      ValueSetter<String> set,
    ) => _ScoreField(
      fieldKey: 'healthScoring.${metric.name}.$suffix',
      label: label,
      value: value,
      isError: error != null,
      onChanged: (text) => vm.edit(metric, (_) => set(text)),
    );
    return [
      Text(
        '${metric.label} · threshold (${metric.unit}) then penalty',
        style: composeBody(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          field(
            'warnAt',
            'warn ≥',
            fields.warnAt,
            errors.warn ?? errors.order,
            (v) => fields.warnAt = v,
          ),
          field(
            'highAt',
            'high ≥',
            fields.highAt,
            errors.high ?? errors.order,
            (v) => fields.highAt = v,
          ),
          field(
            'criticalAt',
            'crit ≥',
            fields.criticalAt,
            errors.crit ?? errors.order,
            (v) => fields.criticalAt = v,
          ),
        ],
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          field(
            'warnPenalty',
            '-pts',
            fields.warnPenalty,
            errors.warnPen,
            (v) => fields.warnPenalty = v,
          ),
          field(
            'highPenalty',
            '-pts',
            fields.highPenalty,
            errors.highPen,
            (v) => fields.highPenalty = v,
          ),
          field(
            'criticalPenalty',
            '-pts',
            fields.criticalPenalty,
            errors.critPen,
            (v) => fields.criticalPenalty = v,
          ),
        ],
      ),
      if (errors.firstError != null)
        Text(
          errors.firstError!,
          key: ValueKey('healthScoring.metric.${metric.name}.error'),
          style: composeBody(fontSize: 11, color: OmniColors.red),
        ),
    ];
  }

  Future<void> _confirmSave(BuildContext context, HealthScoringViewModel vm) async {
    final confirmed = await showOmniConfirm(
      context,
      title: 'Save scoring config?',
      message:
          'Replace the current health-scoring thresholds and penalties? Health scores for all '
          'hosts will be recalculated with the new values.',
      confirmLabel: 'Save',
      keyPrefix: 'healthScoring.save',
    );
    if (confirmed) await vm.save();
  }

  Future<void> _confirmReset(BuildContext context, HealthScoringViewModel vm) async {
    final confirmed = await showOmniConfirm(
      context,
      title: 'Reset to defaults?',
      message:
          'Discard your custom health-scoring thresholds and penalties and restore the built-in '
          'defaults? This cannot be undone.',
      confirmLabel: 'Reset',
      destructive: true,
      keyPrefix: 'healthScoring.reset',
    );
    if (confirmed) await vm.resetToDefaults();
  }
}

/// Kotlin's `ScoreField`: an 82dp outlined field taking only digits and '.', with a 10sp label.
class _ScoreField extends StatefulWidget {
  const _ScoreField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.isError,
    required this.onChanged,
  });

  final String fieldKey;
  final String label;
  final String value;
  final bool isError;
  final ValueChanged<String> onChanged;

  @override
  State<_ScoreField> createState() => _ScoreFieldState();
}

class _ScoreFieldState extends State<_ScoreField> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_ScoreField old) {
    super.didUpdateWidget(old);
    // Saving and resetting replace the draft; the controller would otherwise keep the typed text.
    if (widget.value != _controller.text) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 82,
      child: TextField(
        key: ValueKey(widget.fieldKey),
        controller: _controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        style: composeBody(),
        onChanged: widget.onChanged,
        decoration: omniInputDecoration(context).copyWith(
          label: Text(widget.label, style: const TextStyle(fontSize: 10)),
          enabledBorder: widget.isError
              ? OutlineInputBorder(borderSide: BorderSide(color: scheme.error))
              : null,
          focusedBorder: widget.isError
              ? OutlineInputBorder(borderSide: BorderSide(color: scheme.error, width: 2))
              : null,
        ),
      ),
    );
  }
}
