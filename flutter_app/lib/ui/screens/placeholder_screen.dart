import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// Stands in for a screen that has not been ported yet, naming the legacy Kotlin source it comes
/// from so the migration's remaining surface is visible while running the app.
///
/// Every one of these is removed by the end of the migration; see MIGRATION.md §3.6.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, required this.source});

  final String title;
  final String source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Scrollable so the parent RefreshIndicator always has a scrollable to attach to.
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.construction, size: 40, color: OmniColors.amber),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Not ported yet',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: OmniColors.border),
          ),
          child: Text(
            source,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: OmniFonts.mono,
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
