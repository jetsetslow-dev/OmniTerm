import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../navigation.dart';
import '../../theme/colors.dart';
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

  @override
  Widget build(BuildContext context) {
    final navigation = context.read<NavigationController>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'OmniTerm utilities'),
        Expanded(
          child: GridView.count(
            key: const ValueKey('tools.grid'),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            padding: const EdgeInsets.all(12),
            childAspectRatio: 1.6,
            children: [
              for (final (screen, label, icon) in tools)
                OmniCard(
                  key: ValueKey('tools.${screen.name}'),
                  onTap: () => navigation.navigateTo(screen),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 26, color: OmniColors.cyan),
                      const SizedBox(height: 8),
                      Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
