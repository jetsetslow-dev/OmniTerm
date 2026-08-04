import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'navigation.dart';
import 'screens/shell/shell_screen.dart';
import 'screens/fleet/fleet_screen.dart';
import 'screens/infra/infra_screen.dart';
import 'screens/monitor/monitor_screen.dart';
import 'screens/sftp/sftp_screen.dart';
import 'screens/tools/about_screen.dart';
import 'screens/tools/alerts_screen.dart';
import 'screens/tools/backup_screen.dart';
import 'screens/tools/health_scoring_screen.dart';
import 'screens/tools/auth_keys_screen.dart';
import 'screens/tools/network_screen.dart';
import 'screens/tools/scripts_screen.dart';
import 'screens/tools/settings_screen.dart';
import 'screens/tools/tools_hub_screen.dart';
import 'screens/servers/servers_screen.dart';
import 'shell_state.dart';
import 'theme/colors.dart';
import 'widgets/omni_chrome.dart';

/// The 7 top-level bottom-nav destinations, with the labels and accent colours from
/// `AppCoreScaffold` in `ui/AppUi.kt`.
///
/// Three labels deliberately differ from their `Screen` name and must not be "corrected":
/// Shell shows "Term", SFTP shows "Files" (the screen covers transfers, bookmarks and SMB/FTP/
/// WebDAV shares now, not just SFTP), and Infra shows "Containers".
final _navItems = <OmniNavItem<Screen>>[
  const OmniNavItem(key: Screen.servers, label: 'Servers', icon: Icons.dns, color: OmniColors.cyan),
  const OmniNavItem(key: Screen.fleet, label: 'Fleet', icon: Icons.hub, color: OmniColors.green),
  const OmniNavItem(key: Screen.monitor, label: 'Monitor', icon: Icons.speed, color: OmniColors.amber),
  const OmniNavItem(key: Screen.shell, label: 'Term', icon: Icons.terminal, color: OmniColors.cyan),
  const OmniNavItem(key: Screen.sftp, label: 'Files', icon: Icons.folder_zip, color: OmniColors.orange),
  const OmniNavItem(key: Screen.infra, label: 'Containers', icon: Icons.layers, color: OmniColors.purple),
  const OmniNavItem(key: Screen.tools, label: 'Tools', icon: Icons.build, color: OmniColors.red),
];

/// The app's root scaffold, ported from `AppCoreScaffold` in `ui/AppUi.kt`.
///
/// The structure is reproduced 1:1 — top bar (+ free-plan banner), bottom bar (ad banner + nav),
/// the compact-terminal-IME rule, global gestures, and the always-mounted overlay set.
class AppCoreScaffold extends StatelessWidget {
  const AppCoreScaffold({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final shell = context.watch<ShellState>();
    final current = nav.currentScreen;

    bool activeFor(Screen key) =>
        key == current || (key == Screen.tools && isToolSubScreen(current));

    final activeColor =
        _navItems.where((i) => activeFor(i.key)).firstOrNull?.color ?? OmniColors.cyan;

    final media = MediaQuery.of(context);
    // A landscape software keyboard can consume over half of the physical display. Keeping both
    // global bars mounted in that state left the terminal with zero drawable rows (and made split
    // panes effectively unusable). Terminal-local controls remain available; the global chrome
    // returns as soon as the IME closes.
    final compactTerminalIme = current == Screen.shell &&
        media.viewInsets.bottom > 0 &&
        media.orientation == Orientation.landscape;

    // Natural touch scrolling must stay inside the terminal, so pull-to-refresh and the app-level
    // tab swipe are both disabled on Shell.
    final allowGlobalGestures = current != Screen.shell;

    Widget body = _ScreenBody(screen: current);

    if (allowGlobalGestures) {
      body = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v == 0) return;
          // A leftward fling (negative velocity) advances to the next tab.
          nav.swipeNavigate(forward: v < 0);
        },
        child: RefreshIndicator(
          onRefresh: shell.refreshCurrentScreen,
          backgroundColor: Theme.of(context).colorScheme.surface,
          color: Theme.of(context).colorScheme.primary,
          child: body,
        ),
      );
    }

    return Scaffold(
      appBar: compactTerminalIme
          ? null
          : PreferredSize(
              preferredSize: Size.fromHeight(
                OmniAppBar(
                      activeColor: activeColor,
                      alertCount: shell.visibleAlertCount,
                      keepScreenOn: shell.isKeepScreenOnEnabled,
                      onHome: () {},
                      onAlerts: () {},
                      onToggleKeepScreenOn: () {},
                    ).preferredSize.height +
                    (shell.showFreePlanBanner ? _FreePlanBanner.height : 0),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OmniAppBar(
                    activeColor: activeColor,
                    alertCount: shell.visibleAlertCount,
                    keepScreenOn: shell.isKeepScreenOnEnabled,
                    onHome: () => nav.navigateTo(Screen.servers),
                    onAlerts: shell.openAlertsPopup,
                    onToggleKeepScreenOn: shell.requestKeepScreenOnToggle,
                  ),
                  if (shell.showFreePlanBanner) const _FreePlanBanner(),
                ],
              ),
            ),
      bottomNavigationBar: compactTerminalIme
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (shell.showAdBanner) const _AdBanner(),
                OmniBottomNav<Screen>(
                  items: _navItems,
                  isActive: activeFor,
                  onNavigate: nav.navigateTo,
                ),
              ],
            ),
      body: Stack(
        children: [
          Positioned.fill(child: body),

          // In a landscape terminal the IME intentionally hides both global bars to preserve
          // usable rows. Keep alerts independently reachable even in that compact state.
          if (compactTerminalIme)
            Positioned(
              top: 8,
              right: 8,
              child: SizedBox(
                width: 44,
                height: 44,
                child: FloatingActionButton(
                  onPressed: shell.openAlertsPopup,
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Badge(
                    isLabelVisible: shell.visibleAlertCount > 0,
                    label: Text(shell.visibleAlertCount.clamp(0, 99).toString()),
                    child: Icon(
                      Icons.notifications,
                      color: shell.visibleAlertCount > 0
                          ? OmniColors.red
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),

          // Global overlays are mounted above every tab, exactly as in the Compose scaffold:
          //  - ActionStreamDialog: live output for any button-triggered remote action
          //  - AlertsPopup: navigation-free incident triage (must overlay Shell without invoking
          //    the terminal disconnect/background gate)
          //  - SudoAuthDialog: biometric/PIN gate for a staged privileged action
          //  - battery-saver dialog
          // TODO(migration): mount these once their ViewModels are ported (MIGRATION.md §3.6).
        ],
      ),
    );
  }
}

/// Routes the active [Screen] to its widget. Ported from the `when (viewModel.currentScreen)`
/// block in `AppCoreScaffold`.
class _ScreenBody extends StatelessWidget {
  const _ScreenBody({required this.screen});

  final Screen screen;

  @override
  Widget build(BuildContext context) {
    return switch (screen) {
      Screen.servers => const ServersScreen(),
      Screen.fleet => const FleetScreen(),
      Screen.monitor => const MonitorScreen(),
      Screen.shell => const ShellScreen(),
      Screen.sftp => const SftpScreen(),
      Screen.infra => const InfraScreen(),
      Screen.tools => const ToolsHubScreen(),
      Screen.alerts => const AlertsScreen(),
      Screen.quickScripts => const ScriptsScreen(),
      Screen.network => const NetworkScreen(),
      Screen.authKeys => const AuthKeysScreen(),
      Screen.backup => const BackupScreen(),
      Screen.healthScoring => const HealthScoringScreen(),
      Screen.settings => const SettingsScreen(),
      Screen.about => const AboutScreen(),
    };
  }
}

/// Placeholder for the free-tier disclosure strip. The real banner is billing-driven and lands with
/// the monetization port (MIGRATION.md §3.7).
class _FreePlanBanner extends StatelessWidget {
  const _FreePlanBanner();

  static const double height = 0;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Placeholder for the single bottom ad banner (playStore flavor only).
class _AdBanner extends StatelessWidget {
  const _AdBanner();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
