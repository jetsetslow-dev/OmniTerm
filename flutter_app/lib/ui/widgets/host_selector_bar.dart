import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../domain/host_display.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Picks which host a screen is about.
///
/// Ported from `ServerSelectorBar` in `ui/AppUi.kt:83`, which Kotlin uses on every screen that acts
/// on one host. Flutter had grown a separate `DropdownButton` per screen, and they had drifted:
/// Monitor showed the bare name at 14sp in the default font, Infra showed `Containers · name` at
/// 13sp in mono, and **none of them showed which machine that name actually refers to**.
///
/// That last part is the substance. Kotlin's bar carries `user@host · latency` beside the name, so a
/// fleet with `web-1`, `web-2` and `web-2-old` can be told apart at a glance and a host that has
/// gone quiet is visible without leaving the screen. A picker showing only a nickname cannot do
/// either.
class HostSelectorBar extends StatelessWidget {
  const HostSelectorBar({
    super.key,
    required this.keyPrefix,
    required this.hosts,
    required this.selected,
    required this.onChanged,
    this.labelPrefix = '',
  });

  /// Prefix for this bar's widget keys, so each screen keeps its own stable identifiers.
  final String keyPrefix;

  final List<Server> hosts;
  final Server selected;
  final ValueChanged<int?> onChanged;

  /// Optional text before the host name, e.g. Infra's `Containers · `.
  final String labelPrefix;

  @override
  Widget build(BuildContext context) {
    final display = HostDisplay.instance;
    final accent = OmniColors.serverAccent(selected.serverColor, selected.name);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return DropdownButtonHideUnderline(
      child: DropdownButton<int>(
        key: ValueKey(keyPrefix),
        isExpanded: true,
        value: selected.id,
        icon: Icon(Icons.arrow_drop_down, color: accent),
        // The closed bar and the open list show different things on purpose: the bar is about the
        // host you are on, the list is about telling candidates apart.
        selectedItemBuilder: (context) => [
          for (final host in hosts) _closedLabel(host, display, accent, muted),
        ],
        items: [
          for (final host in hosts)
            DropdownMenuItem(
              value: host.id,
              child: Row(
                children: [
                  _StatusDot(
                    online: host.status == 'online',
                    color: OmniColors.serverAccent(host.serverColor, host.name),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${display.name(host)} — ${display.userAtHost(host)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _closedLabel(Server host, HostDisplay display, Color accent, Color muted) {
    // "offline" rather than a stale number: a latency from before the host went quiet reads as if it
    // were still answering.
    final latency = host.status == 'online' ? '${host.lastLatency}ms' : 'offline';
    return Row(
      key: ValueKey('$keyPrefix.label.${host.id}'),
      children: [
        _StatusDot(online: host.status == 'online', color: accent),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '$labelPrefix${display.name(host)}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontFamily: OmniFonts.mono,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${display.userAtHost(host)} · $latency',
            key: ValueKey('$keyPrefix.detail.${host.id}'),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: muted),
          ),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.online, required this.color});

  final bool online;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(shape: BoxShape.circle, color: online ? color : OmniColors.textMuted),
  );
}
