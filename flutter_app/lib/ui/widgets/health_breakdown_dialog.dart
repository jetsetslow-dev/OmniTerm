import 'package:flutter/material.dart';

import '../../domain/health_scoring.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Explains a host's health score, ported from `HealthBreakdownDialog` in `ui/AppUi.kt`.
///
/// Shared by Monitor and Fleet, which is how the Kotlin has it too: both screens draw the same ring
/// from the same column, and two dialogs would eventually explain it two different ways.
///
/// It takes a [breakdown] rather than a host and a config, so the explanation is always produced by
/// whoever produced the number — a dialog that recomputes the score from whatever it can reach is a
/// dialog that can justify a number nobody wrote.
Future<void> showHealthBreakdown(
  BuildContext context, {
  required String name,
  required HealthBreakdown? breakdown,
}) async {
  if (breakdown == null) return;

  await showDialog<void>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        key: const ValueKey('health.dialog'),
        title: Text('Health score · $name'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Score: ${breakdown.score} / 100',
                key: const ValueKey('health.score'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: OmniFonts.mono),
              ),
              const Divider(height: 16),
              if (breakdown.offline)
                const Text(
                  'Host offline or unreachable — the score is forced to 0.',
                  key: ValueKey('health.offline'),
                  style: TextStyle(fontSize: 14, color: OmniColors.red),
                )
              else if (breakdown.healthy)
                const Text(
                  'Every reading is within its healthy threshold. Nothing was deducted.',
                  key: ValueKey('health.healthy'),
                  style: TextStyle(fontSize: 14, color: OmniColors.green),
                )
              else ...[
                const Text(
                  'Starting from 100, these readings were deducted:',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 6),
                for (final (index, factor) in breakdown.factors.indexed)
                  Padding(
                    key: ValueKey('health.factor.$index'),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(factor.label, style: const TextStyle(fontSize: 14))),
                        Text(
                          '-${factor.penalty}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: OmniColors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const Divider(height: 16),
              Text(
                'Thresholds and weights are editable in Settings → Health scoring.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('health.close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
