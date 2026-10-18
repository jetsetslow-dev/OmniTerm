import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/omni_components.dart';

/// The Tools hub, ported from `ToolsScreen` in `ui/ToolsScreen.kt`.
///
/// A grid of the eight tool screens. Ordered by how often they are reached rather than
/// alphabetically: alerts and scripts are day-to-day, About is a destination you visit once.
class ToolsHubScreen extends StatelessWidget {
  const ToolsHubScreen({super.key});

  static const tools = <(Screen, String, IconData)>[
    (Screen.alerts, 'Alerts & rules', Icons.notifications),
    (Screen.quickScripts, 'Scripts', Icons.code),
    (Screen.network, 'Network tools', Icons.lan),
    (Screen.authKeys, 'Auth & keys', Icons.key),
    (Screen.backup, 'App backup', Icons.backup),
    (Screen.healthScoring, 'Health scoring', Icons.monitor_heart),
    (Screen.settings, 'Settings', Icons.settings),
    (Screen.about, 'About OmniTerm', Icons.info),
  ];

  // Kotlin's label keeps bodyLarge's 24sp line height (see composed()).
  static final _labelStyle = composed(const TextStyle(fontWeight: FontWeight.w600, fontSize: 14));

  /// Kotlin's tiles are a fixed 110dp. Compose clips a label that outgrows one (a two-line label
  /// at large text); Flutter would report the overflow instead, so a tile grows exactly as much
  /// as its tallest label needs at the current width and text scale, and no more.
  static double tileExtent(BuildContext context, double tileWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var tallest = 0.0;
    for (final (_, label, _) in tools) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(_labelStyle)),
        textAlign: TextAlign.center,
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: tileWidth - 24);
      tallest = painter.height > tallest ? painter.height : tallest;
      painter.dispose();
    }
    // Card padding (2 × 12) + icon (28) + gap (8) + label, rounded up so sub-pixel text never
    // overflows.
    final needed = (24 + 28 + 8 + tallest).ceilToDouble();
    return needed > 110 ? needed : 110;
  }

  @override
  Widget build(BuildContext context) {
    final navigation = context.read<NavigationController>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'OmniTerm utilities'),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => GridView(
              key: const ValueKey('tools.grid'),
              padding: const EdgeInsets.all(12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                mainAxisExtent: tileExtent(context, (constraints.maxWidth - 24 - 12) / 2),
              ),
              children: [
                for (final (screen, label, icon) in tools)
                  OmniCard(
                    key: ValueKey('tools.${screen.name}'),
                    onTap: () => navigation.navigateTo(screen),
                    child: SizedBox.expand(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 28, color: OmniColors.cyan),
                          const SizedBox(height: 8),
                          Text(label, textAlign: TextAlign.center, style: _labelStyle),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
