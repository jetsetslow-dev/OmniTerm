import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/app_lock_controller.dart';
import '../../widgets/sudo_auth_dialog.dart';
import '../../view_model/monitor_view_model.dart';
import '../../widgets/health_breakdown_dialog.dart';
import '../../widgets/host_selector_bar.dart';
import '../../widgets/omni_components.dart';
import 'cron_tab.dart';
import 'scripts_tab.dart';
import 'monitor_tabs.dart';

/// The Monitor screen, ported from `MonitorScreen` in `ui/MonitorScreen.kt`.
///
/// A host selector, six sub-tabs in the Kotlin's order, and a reboot action. All of the logic — which
/// host is shown, what each tab loads, how replies are guarded — lives in [MonitorViewModel].
class MonitorScreen extends StatelessWidget {
  const MonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MonitorViewModel>();
    final server = vm.monitoredServer;

    if (server == null) return const _NoOnlineHosts();

    // The chrome yields when vertical space is scarce. In landscape at 200% text the app bar, nav
    // bar, selector and tab strip together leave nothing for the content, and the screen overflowed
    // by 44px. Measured rather than assumed: a threshold on the height this screen is actually
    // given responds to whatever the surrounding chrome has taken, which a fixed size cannot.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          _SelectorBar(
            vm: vm,
            server: server,
            compact: constraints.maxHeight < monitorCompactChromeHeight,
          ),
          _TabBar(vm: vm),
          if (vm.error != null) _ErrorBanner(message: vm.error!),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: switch (vm.activeTab) {
                MonitorTab.overview => OverviewTab(vm: vm, server: server),
                MonitorTab.processes => ProcessesTab(vm: vm),
                MonitorTab.services => ServicesTab(vm: vm),
                MonitorTab.logs => LogsTab(vm: vm),
                MonitorTab.scripts => ScriptsTab(vm: vm),
                MonitorTab.cron => CronTab(vm: vm),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Below this much height, Monitor drops its score ring and tightens its padding.
///
/// A landscape phone at 200% text lands under it; a portrait phone at any size does not. Named so
/// the threshold is one decision in one place rather than a number buried in a layout.
const double monitorCompactChromeHeight = 420;

class _NoOnlineHosts extends StatelessWidget {
  const _NoOnlineHosts();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('monitor.noHosts'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, size: 40, color: OmniColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'No online hosts available to monitor',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which host is being monitored, its health ring, and the reboot action.
class _SelectorBar extends StatelessWidget {
  const _SelectorBar({required this.vm, required this.server, this.compact = false});

  /// Drops the score ring and tightens the padding when the screen is short.
  ///
  /// The ring is the first thing to go because it is the only chrome here that is *not* a control:
  /// the host picker switches hosts and the reboot button acts, while the ring reports a number
  /// available on the Overview tab directly below it.
  final bool compact;

  final MonitorViewModel vm;
  final Server server;

  @override
  Widget build(BuildContext context) {
    final online = context.select<MonitorViewModel, List<Server>>((m) => m.onlineServers);
    final accent = OmniColors.serverAccent(server.serverColor, server.name);

    // HostDisplay is an observable singleton, so it must be listened to rather than merely read —
    // otherwise "Hide sensitive info" would leave this bar showing the address.
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(12, compact ? 2 : 8, 4, compact ? 0 : 4),
        child: Row(
          children: [
            // The ring is the only place the score appears, and a number between 0 and 100 with no
            // stated reason is not information. Tapping it says which readings cost what.
            if (!compact)
              InkWell(
                key: const ValueKey('monitor.healthScore.open'),
                onTap: () => showHealthBreakdown(
                  context,
                  name: HostDisplay.instance.name(server),
                  breakdown: vm.healthBreakdown,
                ),
                customBorder: const CircleBorder(),
                child: _ScoreRing(score: server.healthScore, color: accent),
              ),
            if (!compact) const SizedBox(width: 10),
            Expanded(
              child: HostSelectorBar(
                keyPrefix: 'monitor.hostPicker',
                hosts: online,
                selected: server,
                onChanged: vm.selectServer,
              ),
            ),
            IconButton(
              key: const ValueKey('monitor.reboot'),
              tooltip: 'Reboot host',
              icon: const Icon(Icons.restart_alt, size: 18, color: OmniColors.red),
              onPressed: () => _confirmReboot(context, vm, server),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReboot(BuildContext context, MonitorViewModel vm, Server server) async {
    // Rebooting is destructive and irreversible from the app's side, so it is always confirmed and
    // the dialog says plainly what will run and what it needs.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('monitor.reboot.dialog'),
        title: Text('Reboot ${server.name}?'),
        content: Text(
          'This runs `sudo reboot` on ${HostDisplay.instance.host(server)}. '
          'The host will drop offline until it comes back up. '
          'Requires sudo rights for the SSH user.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('monitor.reboot.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('monitor.reboot.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reboot', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;

    // Re-authenticate before the *stored* sudo password is used. Confirming a reboot answers "did
    // you mean this"; it does not answer "are you the person who saved that password". Kotlin gates
    // the same two actions through `withSudoAuth` (`ui/AppViewModel.kt:2521`).
    final lock = context.read<AppLockController>();
    if (lock.requiresSudoAuth(server.sudoPassword)) {
      if (!await requestSudoAuth(context, lock)) return;
    }
    await vm.rebootMonitoredHost();
  }
}

class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score, required this.color});

  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: (score / 100).clamp(0.0, 1.0),
            strokeWidth: 3,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(
              score >= 70
                  ? OmniColors.green
                  : score >= 40
                  ? OmniColors.amber
                  : OmniColors.red,
            ),
          ),
          Text(
            '$score',
            key: const ValueKey('monitor.healthScore'),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.vm});

  final MonitorViewModel vm;

  static const _labels = {
    MonitorTab.overview: 'Overview',
    MonitorTab.processes: 'Processes',
    MonitorTab.services: 'Services',
    MonitorTab.logs: 'Logs',
    MonitorTab.scripts: 'Scripts',
    MonitorTab.cron: 'CRON',
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Deliberately *not* scaled with the text, unlike the SFTP and Infra strips. Monitor's body
      // is `Column(selector, tabs, Expanded)`, and in landscape at 200% the chrome already exceeds
      // the viewport — a taller bar took the overflow from 44px to 84px. The chips clip a little
      // here; the fix is to make the chrome itself tolerate a short viewport, which is defect 48.
      height: 40,
      child: ListView(
        key: const ValueKey('monitor.tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final tab in MonitorTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: ChoiceChip(
                  key: ValueKey('monitor.tab.${tab.name}'),
                  label: Text(_labels[tab]!, style: const TextStyle(fontSize: 12)),
                  selected: vm.activeTab == tab,
                  onSelected: (_) => vm.activeTab = tab,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OmniCard(
        key: const ValueKey('monitor.error'),
        leftAccent: OmniColors.red,
        // Bounded. This banner sits in the screen's `Column` above an `Expanded`, so an unbounded
        // message competes with the content for height rather than pushing it down: a refused
        // connection at 200% text wrapped to six monospace lines and overflowed the whole screen by
        // 44px in landscape. Three lines keep the part that names the failure — SSH errors lead
        // with it — without the banner owning the pane it is reporting about.
        child: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono),
        ),
      ),
    );
  }
}

/// Stands in for a tab whose port has not landed yet.
///
/// Named plainly rather than left blank: an empty pane reads as "this host has nothing", which is a
/// different and misleading claim.
