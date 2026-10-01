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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Builder(
        builder: (anchorContext) => DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: InkWell(
            key: ValueKey(keyPrefix),
            borderRadius: BorderRadius.circular(8),
            onTap: hosts.isEmpty ? null : () => _showHosts(anchorContext),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: _closedLabel(context, selected, display, accent, muted),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showHosts(BuildContext context) async {
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final chosen = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy + anchor.size.height, anchor.size.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints.tightFor(width: anchor.size.width),
      semanticLabel: 'Switch host',
      items: [
        for (final host in hosts)
          PopupMenuItem(
            key: ValueKey('$keyPrefix.item.${host.id}'),
            value: host.id,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    heightFactor: 1,
                    child: _StatusDot(
                      online: host.status == 'online',
                      color: OmniColors.serverAccent(host.serverColor, host.name),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${HostDisplay.instance.name(host)} — ${HostDisplay.instance.userAtHost(host)}',
                    overflow: TextOverflow.ellipsis,
                    style: _menuStyle(context),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (context.mounted && chosen != null && chosen != selected.id) onChanged(chosen);
  }

  TextStyle _menuStyle(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // DropdownMenuItem in the resolved Material3 library supplies labelLarge, not bodyLarge.
    return Theme.of(context).textTheme.labelLarge!.copyWith(
      fontFamily: OmniFonts.mono,
      fontSize: 14,
      height: scaler.scale(20) / scaler.scale(14),
      letterSpacing: scaler.scale(.1),
    );
  }

  TextStyle _labelStyle(BuildContext context, double size, {double letterSpacing = .5}) {
    final scaler = MediaQuery.textScalerOf(context);
    // Compose retains bodyLarge's 24sp line height when these labels change font size. Scale
    // that line and sp letter spacing separately; Flutter scales only the font size itself.
    return Theme.of(context).textTheme.bodyLarge!.copyWith(
      fontSize: size,
      height: scaler.scale(24) / scaler.scale(size),
      letterSpacing: scaler.scale(letterSpacing),
    );
  }

  Widget _closedLabel(
    BuildContext context,
    Server host,
    HostDisplay display,
    Color accent,
    Color muted,
  ) {
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _labelStyle(
              context,
              16,
            ).copyWith(fontWeight: FontWeight.bold, fontFamily: OmniFonts.mono),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${display.userAtHost(host)} · $latency',
            key: ValueKey('$keyPrefix.detail.${host.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _labelStyle(context, 12).copyWith(color: muted),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'HOST',
          style: _labelStyle(
            context,
            10,
            letterSpacing: 1,
          ).copyWith(fontWeight: FontWeight.bold, color: accent),
        ),
        const SizedBox(width: 8),
        Icon(Icons.arrow_drop_down, color: accent, semanticLabel: 'Switch host'),
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
