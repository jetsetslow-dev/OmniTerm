import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// A bottom-navigation destination. `key` is deliberately untyped in the legacy code
/// (`OmniNavItem(val key: Any, …)`) so the bar can serve non-`Screen` keys too; the Dart port keeps
/// that flexibility with a generic.
@immutable
class OmniNavItem<K> {
  const OmniNavItem({
    required this.key,
    required this.label,
    required this.icon,
    required this.color,
  });

  final K key;
  final String label;
  final IconData icon;
  final Color color;
}

/// Top app bar: brand + keep-screen-on toggle + alert badge.
///
/// Ported from `OmniAppBar` in `ui/OmniComponents.kt`. Fixed 52dp content height below the status
/// bar, a 1px bottom hairline in [OmniColors.border], and a status-bar-coloured surface behind it
/// (the app renders edge-to-edge).
class OmniAppBar extends StatelessWidget implements PreferredSizeWidget {
  const OmniAppBar({
    super.key,
    required this.activeColor,
    required this.alertCount,
    required this.keepScreenOn,
    required this.onHome,
    required this.onAlerts,
    required this.onToggleKeepScreenOn,
  });

  final Color activeColor;
  final int alertCount;
  final bool keepScreenOn;
  final VoidCallback onHome;
  final VoidCallback onAlerts;
  final VoidCallback onToggleKeepScreenOn;

  static const double _contentHeight = 52;

  @override
  Size get preferredSize => const Size.fromHeight(_contentHeight);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surface,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: _contentHeight,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: OmniColors.border, width: 1)),
          ),
          child: Row(
            children: [
              InkWell(
                onTap: onHome,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: activeColor, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'OMNITERM',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontFamily: OmniFonts.display,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onToggleKeepScreenOn,
                tooltip: keepScreenOn ? 'Disable keep screen on' : 'Enable keep screen on',
                icon: Icon(
                  Icons.lightbulb,
                  color: keepScreenOn ? OmniColors.amber : scheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                onPressed: onAlerts,
                tooltip: alertCount > 0
                    ? 'Open alerts popup, $alertCount active'
                    : 'Open alerts popup',
                icon: Badge(
                  isLabelVisible: alertCount > 0,
                  // The legacy bar clamps the badge text at 99 rather than showing "99+".
                  label: Text(alertCount.clamp(0, 99).toString()),
                  child: Icon(
                    Icons.notifications,
                    color: alertCount > 0 ? OmniColors.red : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom navigation bar. Ported from `OmniBottomNav` in `ui/OmniComponents.kt`.
///
/// Each item is an equal-weight column with a 2px accent rule along its top edge when active; the
/// whole bar carries a 1px [OmniColors.border] hairline above it and sits above the system
/// navigation-bar inset.
class OmniBottomNav<K> extends StatelessWidget {
  const OmniBottomNav({
    super.key,
    required this.items,
    required this.isActive,
    required this.onNavigate,
  });

  final List<OmniNavItem<K>> items;
  final bool Function(K key) isActive;
  final void Function(K key) onNavigate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: const Border(top: BorderSide(color: OmniColors.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (final item in items)
              Expanded(
                child: InkWell(
                  // Convention 1. The bar is the most-tapped control in the app and was the one
                  // thing the E2E suite could not target, so flows had to fall back to raw screen
                  // coordinates — which is how a manual walk mis-tapped a password into a name
                  // field. `item.key` is the `Screen` enum value, so this reads `nav.monitor`.
                  key: ValueKey('nav.${item.key is Enum ? (item.key as Enum).name : item.key}'),
                  onTap: () => onNavigate(item.key),
                  child: Container(
                    // a11y touch-target floor
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.only(top: 8, bottom: 6),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: isActive(item.key) ? item.color : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.icon,
                          size: 20,
                          color: isActive(item.key) ? item.color : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isActive(item.key) ? item.color : scheme.onSurfaceVariant,
                            fontFamily: OmniFonts.mono,
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
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
