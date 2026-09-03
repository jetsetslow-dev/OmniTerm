import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_database.dart';
import '../domain/alert_evaluation.dart';
import '../domain/external_ui_requests.dart';
import '../platform/license_controller.dart';
import '../platform/ads_controller.dart';
import '../platform/battery_saver_controller.dart';
import '../platform/shortcut_helper.dart';
import '../platform/platform_permissions.dart';
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
import 'theme/typography.dart';
import 'view_model/alerts_view_model.dart';
import 'view_model/app_state.dart';
import 'view_model/host_status_probe.dart';
import 'view_model/infra_view_model.dart';
import 'view_model/monitor_view_model.dart';
import 'view_model/network_view_model.dart';
import 'view_model/servers_view_model.dart';
import 'view_model/sftp_view_model.dart';
import 'view_model/shell_view_model.dart';
import 'view_model/telemetry_poller.dart';
import 'widgets/ad_banner.dart';
import '../domain/permission_copy.dart';
import 'widgets/host_limit_gate.dart';
import 'widgets/omni_chrome.dart';
import 'widgets/omni_components.dart';

/// The 7 top-level bottom-nav destinations, with the labels and accent colours from
/// `AppCoreScaffold` in `ui/AppUi.kt`.
///
/// Three labels deliberately differ from their `Screen` name and must not be "corrected":
/// Shell shows "Term", SFTP shows "Files" (the screen covers transfers, bookmarks and SMB/FTP/
/// WebDAV shares now, not just SFTP), and Infra shows "Containers".
final _navItems = <OmniNavItem<Screen>>[
  const OmniNavItem(key: Screen.servers, label: 'Servers', icon: Icons.dns, color: OmniColors.cyan),
  const OmniNavItem(key: Screen.fleet, label: 'Fleet', icon: Icons.hub, color: OmniColors.green),
  const OmniNavItem(
    key: Screen.monitor,
    label: 'Monitor',
    icon: Icons.speed,
    color: OmniColors.amber,
  ),
  const OmniNavItem(key: Screen.shell, label: 'Term', icon: Icons.terminal, color: OmniColors.cyan),
  const OmniNavItem(
    key: Screen.sftp,
    label: 'Files',
    icon: Icons.folder_zip,
    color: OmniColors.orange,
  ),
  const OmniNavItem(
    key: Screen.infra,
    label: 'Containers',
    icon: Icons.layers,
    color: OmniColors.purple,
  ),
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
    final license = context.read<LicenseController>();
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
    final compactTerminalIme =
        current == Screen.shell &&
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
          onRefresh: () => shell.refreshCurrentScreen(() => _refreshScreen(context, current)),
          backgroundColor: Theme.of(context).colorScheme.surface,
          color: Theme.of(context).colorScheme.primary,
          child: body,
        ),
      );
    }

    final overlayBody = Stack(
      // The permission host is normally a zero-sized, non-positioned child. The expanded fit makes
      // the real screen establish the viewport while every conditional dialog layers over it.
      fit: StackFit.expand,
      children: [
        body,
        // Over every screen, because the install is in a state no screen should be usable from
        // until it is resolved. Renders nothing at all unless there is a violation.
        const HostLimitGate(),
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
        if (shell.showAlertsPopup)
          _AlertsPopup(vm: context.watch<AlertsViewModel>(), onDismiss: shell.closeAlertsPopup),
        if (shell.showKeepScreenOnWarning) _KeepScreenOnWarning(shell: shell),
        if (context.watch<BatterySaverController>().showDialog)
          _BatterySaverDialog(controller: context.read<BatterySaverController>()),
        if (shell.hostLimitReconciliationRequired)
          _HostLimitReconciliationDialog(reason: shell.hostLimitReconciliationReason),
        const _PermissionPromptHost(),
      ],
    );

    // A phone in landscape has tablet width but very little height. Keeping the 52dp app bar,
    // 96dp free-plan banner and bottom navigation left less than half the display for several
    // screens. The same destinations and global actions move to a scrollable side rail, while an
    // explicit FREE item keeps the entitlement visible and actionable.
    if (media.orientation == Orientation.landscape && !compactTerminalIme) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              _LandscapeNav(
                items: _navItems,
                isActive: activeFor,
                onNavigate: nav.navigateTo,
                activeColor: activeColor,
                alertCount: shell.visibleAlertCount,
                keepScreenOn: shell.isKeepScreenOnEnabled,
                showFreePlan: shell.showFreePlanBanner,
                onHome: () => nav.navigateTo(Screen.servers),
                onAlerts: shell.openAlertsPopup,
                onToggleKeepScreenOn: shell.requestKeepScreenOnToggle,
                onUnlock: license.launchPurchase,
              ),
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: overlayBody),
                    if (shell.showAdBanner)
                      AdBanner(
                        licenseController: license,
                        adsController: context.read<AdsController>(),
                      ),
                  ],
                ),
              ),
            ],
          ),
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
                  if (shell.showFreePlanBanner) _FreePlanBanner(controller: license),
                ],
              ),
            ),
      bottomNavigationBar: compactTerminalIme
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (shell.showAdBanner)
                  AdBanner(
                    licenseController: license,
                    adsController: context.read<AdsController>(),
                  ),
                OmniBottomNav<Screen>(
                  items: _navItems,
                  isActive: activeFor,
                  onNavigate: nav.navigateTo,
                ),
              ],
            ),
      body: overlayBody,
    );
  }

  Future<void> _refreshScreen(BuildContext context, Screen screen) async {
    context.read<BatterySaverController>().resume();
    switch (screen) {
      case Screen.servers:
      case Screen.fleet:
      case Screen.alerts:
        final probe = context.read<HostStatusProbe>();
        final poller = context.read<TelemetryPoller>();
        await probe.sweep();
        await poller.cycle();
      case Screen.monitor:
        await context.read<MonitorViewModel>().loadActiveTab();
      case Screen.infra:
        await context.read<InfraViewModel>().load();
      case Screen.sftp:
        final vm = context.read<SftpViewModel>();
        if (vm.activeTab == SftpTab.files && vm.hasBrowseTarget) {
          await vm.refresh();
        }
      case Screen.network:
        await _refreshNetwork(context.read<NetworkViewModel>());
      case Screen.shell:
      case Screen.tools:
      case Screen.quickScripts:
      case Screen.authKeys:
      case Screen.backup:
      case Screen.healthScoring:
      case Screen.settings:
      case Screen.about:
        return;
    }
  }

  Future<void> _refreshNetwork(NetworkViewModel vm) => switch (vm.activeTab) {
    NetworkTab.hostScan => vm.scanSubnet(),
    NetworkTab.ping => vm.runPing(),
    NetworkTab.traceroute => vm.runTraceroute(),
    NetworkTab.portScan => vm.runPortScan(),
    NetworkTab.dnsLookup => vm.runDnsLookup(),
    NetworkTab.whois => vm.runWhois(),
    NetworkTab.speedTest => vm.runSpeedTest(),
    NetworkTab.wakeOnLan || NetworkTab.tunnels => Future<void>.value(),
  };
}

class _LandscapeNav extends StatelessWidget {
  const _LandscapeNav({
    required this.items,
    required this.isActive,
    required this.onNavigate,
    required this.activeColor,
    required this.alertCount,
    required this.keepScreenOn,
    required this.showFreePlan,
    required this.onHome,
    required this.onAlerts,
    required this.onToggleKeepScreenOn,
    required this.onUnlock,
  });

  final List<OmniNavItem<Screen>> items;
  final bool Function(Screen) isActive;
  final ValueChanged<Screen> onNavigate;
  final Color activeColor;
  final int alertCount;
  final bool keepScreenOn;
  final bool showFreePlan;
  final VoidCallback onHome;
  final VoidCallback onAlerts;
  final VoidCallback onToggleKeepScreenOn;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 82,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: const Border(right: BorderSide(color: OmniColors.border)),
      ),
      child: ListView(
        key: const ValueKey('nav.landscape'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          Tooltip(
            message: 'Servers home',
            child: InkWell(
              onTap: onHome,
              child: SizedBox(
                height: 40,
                child: Center(
                  child: Text(
                    'OT',
                    style: TextStyle(
                      color: activeColor,
                      fontFamily: OmniFonts.display,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final item in items)
            _LandscapeNavItem(
              item: item,
              active: isActive(item.key),
              onTap: () => onNavigate(item.key),
            ),
          const Divider(height: 8),
          _LandscapeAction(
            tooltip: keepScreenOn ? 'Disable keep screen on' : 'Enable keep screen on',
            label: 'Awake',
            icon: Icons.lightbulb,
            color: keepScreenOn ? OmniColors.amber : scheme.onSurfaceVariant,
            onTap: onToggleKeepScreenOn,
          ),
          _LandscapeAction(
            tooltip: alertCount > 0 ? 'Open alerts, $alertCount active' : 'Open alerts',
            label: 'Alerts',
            icon: Icons.notifications,
            color: alertCount > 0 ? OmniColors.red : scheme.onSurfaceVariant,
            badge: alertCount,
            onTap: onAlerts,
          ),
          if (showFreePlan)
            _LandscapeAction(
              tooltip: 'Free plan — unlock unlimited hosts',
              label: 'FREE',
              icon: Icons.workspace_premium,
              color: OmniColors.cyan,
              onTap: onUnlock,
            ),
        ],
      ),
    );
  }
}

class _LandscapeNavItem extends StatelessWidget {
  const _LandscapeNavItem({required this.item, required this.active, required this.onTap});

  final OmniNavItem<Screen> item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? item.color : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: item.label,
      child: InkWell(
        key: ValueKey('nav.${item.key.name}'),
        onTap: onTap,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: active ? item.color : Colors.transparent, width: 3),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 19, color: color),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontFamily: OmniFonts.mono,
                  fontWeight: FontWeight.bold,
                  fontSize: 8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LandscapeAction extends StatelessWidget {
  const _LandscapeAction({
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.badge = 0,
  });

  final String tooltip;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Badge(
              isLabelVisible: badge > 0,
              label: Text(badge.clamp(0, 99).toString()),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontFamily: OmniFonts.mono,
                fontWeight: FontWeight.bold,
                fontSize: 8,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HostLimitReconciliationDialog extends StatefulWidget {
  const _HostLimitReconciliationDialog({required this.reason});

  final String reason;

  @override
  State<_HostLimitReconciliationDialog> createState() => _HostLimitReconciliationDialogState();
}

class _HostLimitReconciliationDialogState extends State<_HostLimitReconciliationDialog> {
  int? _selectedId;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final servers = context.watch<AppState>().servers;
    _selectedId ??= servers.firstOrNull?.id;
    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Center(
          child: AlertDialog(
            key: const ValueKey('license.hostReconciliation'),
            title: const Text('Choose host to keep'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.reason.isEmpty
                          ? 'The free Play Store build supports one saved host.'
                          : widget.reason,
                    ),
                    const SizedBox(height: 10),
                    RadioGroup<int>(
                      groupValue: _selectedId,
                      onChanged: _busy ? (_) {} : (value) => setState(() => _selectedId = value),
                      child: Column(
                        children: [
                          for (final server in servers)
                            RadioListTile<int>(
                              key: ValueKey('license.hostReconciliation.${server.id}'),
                              value: server.id,
                              enabled: !_busy,
                              title: Text(
                                server.name.isEmpty ? server.host : server.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${server.username}@${server.host}:${server.port}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                key: const ValueKey('license.hostReconciliation.keep'),
                onPressed: _busy || _selectedId == null ? null : _keepSelected,
                child: Text(_busy ? 'Applying…' : 'Keep selected'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _keepSelected() async {
    final keepId = _selectedId;
    if (keepId == null) return;
    setState(() => _busy = true);
    final app = context.read<AppState>();
    final shell = context.read<ShellViewModel>();
    final network = context.read<NetworkViewModel>();
    final servers = context.read<ServersViewModel>();
    final removedIds = app.servers
        .where((server) => server.id != keepId)
        .map((server) => server.id)
        .toSet();

    for (final session
        in shell.sessions.where((session) => removedIds.contains(session.serverId)).toList()) {
      if (session.tmuxName != null) {
        await shell.terminate(session);
      } else {
        shell.close(session);
      }
    }
    for (final tunnel
        in network.portForwards.where((tunnel) => removedIds.contains(tunnel.serverId)).toList()) {
      await network.deleteTunnel(tunnel);
    }
    for (final id in removedIds) {
      await servers.deleteServer(id);
    }
    app.selectedServerId = keepId;
    if (!mounted) return;
    context.read<NavigationController>().navigateTo(Screen.servers);
    context.read<ShellState>().completeHostLimitReconciliation();
  }
}

class _PermissionPromptHost extends StatefulWidget {
  const _PermissionPromptHost();

  @override
  State<_PermissionPromptHost> createState() => _PermissionPromptHostState();
}

class _PermissionPromptHostState extends State<_PermissionPromptHost> with WidgetsBindingObserver {
  bool _checking = false;
  bool _localRequired = false;
  bool _localGranted = true;
  bool _notificationGranted = true;
  bool _batteryExempt = true;
  bool _localDismissed = false;
  bool _backgroundDismissed = false;
  int _dependencyFingerprint = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.watch<AppState>();
    final shell = context.watch<ShellViewModel>();
    final screen = context.watch<NavigationController>().currentScreen;
    final fingerprint = Object.hash(
      app.servers.length,
      app.preferences.backgroundKeepAlive,
      shell.sessions.where((session) => session.isOpen).length,
      screen,
    );
    if (fingerprint != _dependencyFingerprint) {
      _dependencyFingerprint = fingerprint;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_checking || !mounted) return;
    _checking = true;
    final permissions = context.read<PlatformPermissions>();
    final values = await Future.wait([
      permissions.localNetworkRequired,
      permissions.localNetworkGranted,
      permissions.notificationGranted,
      permissions.batteryExempt,
    ]);
    if (mounted) {
      setState(() {
        _localRequired = values[0];
        _localGranted = values[1];
        _notificationGranted = values[2];
        _batteryExempt = values[3];
      });
    }
    _checking = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final shell = context.watch<ShellViewModel>();
    final screen = context.watch<NavigationController>().currentScreen;
    final needsLanForContext =
        app.servers.isNotEmpty ||
        const {Screen.network, Screen.sftp, Screen.fleet, Screen.monitor}.contains(screen);
    final needsLocal = _localRequired && !_localGranted && needsLanForContext && !_localDismissed;
    final needsBackground =
        app.preferences.backgroundKeepAlive &&
        shell.sessions.any((session) => session.isOpen) &&
        (!_notificationGranted || !_batteryExempt) &&
        !_backgroundDismissed;
    if (!needsLocal && !needsBackground) return const SizedBox.shrink();

    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Center(
          child: needsLocal
              ? AlertDialog(
                  key: const ValueKey('permissions.localNetwork'),
                  title: const Text('Connect to devices on your network'),
                  content: const Text(localNetworkPermissionExplanation),
                  actions: [
                    TextButton(
                      onPressed: () => setState(() => _localDismissed = true),
                      child: const Text('Not now'),
                    ),
                    FilledButton(
                      key: const ValueKey('permissions.localNetwork.allow'),
                      onPressed: () async {
                        final granted = await context
                            .read<PlatformPermissions>()
                            .requestLocalNetwork();
                        if (mounted) setState(() => _localGranted = granted);
                      },
                      child: const Text('Allow nearby devices'),
                    ),
                  ],
                )
              : AlertDialog(
                  key: const ValueKey('permissions.backgroundSessions'),
                  title: const Text('Keep sessions active in background'),
                  content: const Text(
                    'Notification access and a battery-optimization exemption improve background '
                    'SSH reliability. They are optional; foreground terminals continue to work '
                    'without them.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => setState(() => _backgroundDismissed = true),
                      child: const Text('Not now'),
                    ),
                    FilledButton(
                      key: const ValueKey('permissions.backgroundSessions.grant'),
                      onPressed: () async {
                        final permissions = context.read<PlatformPermissions>();
                        if (!_notificationGranted) {
                          final granted = await permissions.requestNotifications();
                          if (!granted) {
                            await permissions.openAppSettings();
                            return;
                          }
                        }
                        await permissions.openBatterySettings();
                        await _refresh();
                      },
                      child: const Text('Grant permissions'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _BatterySaverDialog extends StatelessWidget {
  const _BatterySaverDialog({required this.controller});

  final BatterySaverController controller;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: Material(
      color: Colors.black54,
      child: Center(
        child: AlertDialog(
          key: const ValueKey('batterySaver.dialog'),
          title: const Text('Battery saver available'),
          content: Text(
            'Battery reached ${controller.engagedAtPercent}% (threshold '
            '${controller.thresholdPercent}%). OmniTerm can release keep-screen-on, pause '
            'auto-refresh, and park persistent tmux terminals. Nothing will change unless you '
            'choose Start saving.',
          ),
          actions: [
            TextButton(
              key: const ValueKey('batterySaver.notNow'),
              onPressed: controller.dismissDialog,
              child: const Text('Not now'),
            ),
            TextButton(
              key: const ValueKey('batterySaver.confirm'),
              onPressed: controller.confirm,
              child: const Text('Start saving'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Routes the active [Screen] to its widget. Ported from the `when (viewModel.currentScreen)`
/// block in `AppCoreScaffold`.
class _ScreenBody extends StatelessWidget {
  const _ScreenBody({required this.screen});

  final Screen screen;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey('screen.${screen.name}'),
      child: switch (screen) {
        Screen.servers => ServersScreen(
          licenseController: context.read<LicenseController>(),
          externalUiRequests: context.watch<ExternalUiRequests>(),
          navigation: context.read<NavigationController>(),
          telemetry: context.watch<TelemetryPoller>(),
          hostProbe: context.read<HostStatusProbe>(),
          shell: context.read<ShellViewModel>(),
          sftp: context.read<SftpViewModel>(),
          shortcuts: context.read<ShortcutHelper>(),
        ),
        Screen.fleet => const FleetScreen(),
        Screen.monitor => const MonitorScreen(),
        Screen.shell => ShellScreen(licenseController: context.read<LicenseController>()),
        Screen.sftp => const SftpScreen(),
        Screen.infra => const InfraScreen(),
        Screen.tools => const ToolsHubScreen(),
        Screen.alerts => const AlertsScreen(),
        Screen.quickScripts => const ScriptsScreen(),
        Screen.network => const NetworkScreen(),
        Screen.authKeys => AuthKeysScreen(licenseController: context.read<LicenseController>()),
        Screen.backup => const BackupScreen(),
        Screen.healthScoring => const HealthScoringScreen(),
        Screen.settings => const SettingsScreen(),
        Screen.about => const AboutScreen(),
      },
    );
  }
}

class _FreePlanBanner extends StatelessWidget {
  const _FreePlanBanner({required this.controller});

  final LicenseController controller;

  static const double height = 96;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<LicenseState>(
    valueListenable: controller.state,
    builder: (context, state, _) => Container(
      key: const ValueKey('license.freePlanBanner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: OmniColors.cyan.withValues(alpha: 0.12),
        border: Border.all(color: OmniColors.cyan.withValues(alpha: 0.28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium, size: 18, color: OmniColors.cyan),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.adsRemoved
                      ? 'Free Play Store build: 1 host & 1 credential'
                      : 'Free, ad-supported build: 1 host & 1 credential',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const ValueKey('license.restore'),
                onPressed: state.loading ? null : controller.refresh,
                child: const Text('Restore', style: TextStyle(fontSize: 11)),
              ),
              if (!state.adsRemoved)
                TextButton(
                  key: const ValueKey('license.removeAds'),
                  onPressed: state.loading ? null : controller.launchAdRemovalPurchase,
                  child: Text(
                    state.loading
                        ? 'Checking…'
                        : state.adRemovalPrice == null
                        ? 'Remove ads'
                        : 'Remove ads ${state.adRemovalPrice}',
                    style: const TextStyle(fontSize: 11, color: OmniColors.green),
                  ),
                ),
              TextButton(
                key: const ValueKey('license.unlock'),
                onPressed: state.loading ? null : controller.launchPurchase,
                child: Text(
                  state.loading
                      ? 'Checking…'
                      : state.productPrice == null
                      ? 'Unlock unlimited'
                      : 'Unlock unlimited ${state.productPrice}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          if (state.message != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                state.message!,
                style: const TextStyle(fontSize: 11, color: OmniColors.amber),
              ),
            ),
        ],
      ),
    ),
  );
}

class _KeepScreenOnWarning extends StatelessWidget {
  const _KeepScreenOnWarning({required this.shell});

  final ShellState shell;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: Material(
      color: Colors.black54,
      child: Center(
        child: AlertDialog(
          key: const ValueKey('keepScreenOn.warning'),
          title: const Text('Keep screen on'),
          content: const Text(
            'Keeping the screen on prevents display sleep and uses more battery. '
            'Battery saver may turn it off when power is low.',
          ),
          actions: [
            TextButton(
              key: const ValueKey('keepScreenOn.cancel'),
              onPressed: shell.cancelKeepScreenOnWarning,
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('keepScreenOn.enable'),
              onPressed: shell.confirmKeepScreenOn,
              child: const Text('Enable'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AlertsPopup extends StatefulWidget {
  const _AlertsPopup({required this.vm, required this.onDismiss});

  final AlertsViewModel vm;
  final VoidCallback onDismiss;

  @override
  State<_AlertsPopup> createState() => _AlertsPopupState();
}

class _AlertsPopupState extends State<_AlertsPopup> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final active = widget.vm.activeAlerts
        .where((alert) => !alert.acknowledged && alert.mutedUntil < now)
        .toList();
    final muted = widget.vm.activeAlerts.where((alert) => alert.mutedUntil >= now).toList();
    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
            child: Material(
              key: const ValueKey('alerts.popup'),
              borderRadius: BorderRadius.circular(14),
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.notifications_active, size: 20, color: OmniColors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Active alerts',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                '${active.length} firing · ${muted.length} muted',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Dismiss',
                          key: const ValueKey('alerts.popup.close'),
                          onPressed: widget.onDismiss,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    if (active.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('alerts.popup.ackAll'),
                          onPressed: widget.vm.acknowledgeAll,
                          child: const Text('Acknowledge all'),
                        ),
                      ),
                    Flexible(
                      child: active.isEmpty && muted.isEmpty
                          ? const SizedBox(
                              height: 140,
                              child: Center(child: Text('No active alert incidents.')),
                            )
                          : ListView(
                              key: const ValueKey('alerts.popup.list'),
                              shrinkWrap: true,
                              children: [
                                for (final alert in active)
                                  _PopupIncident(vm: widget.vm, alert: alert, muted: false),
                                if (muted.isNotEmpty)
                                  const Padding(
                                    padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
                                    child: Text(
                                      'Muted incidents',
                                      style: TextStyle(
                                        color: OmniColors.purple,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                for (final alert in muted)
                                  _PopupIncident(vm: widget.vm, alert: alert, muted: true),
                              ],
                            ),
                    ),
                    const Divider(),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Rules and incident history are available in Tools → Alerts.',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PopupIncident extends StatelessWidget {
  const _PopupIncident({required this.vm, required this.alert, required this.muted});

  final AlertsViewModel vm;
  final ActiveAlert alert;
  final bool muted;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: OmniCard(
      leftAccent: alert.severity == 'CRITICAL' ? OmniColors.red : OmniColors.amber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${alert.metricName} · ${vm.scopeLabel(alert.serverId)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '${alert.currentValue.round()}${unitFor(alert.metricName)} '
            '(threshold ${alert.thresholdValue.round()}${unitFor(alert.metricName)})',
            style: const TextStyle(fontSize: 11),
          ),
          Row(
            children: [
              if (!muted)
                TextButton(
                  onPressed: () => vm.acknowledge(alert),
                  child: const Text('Acknowledge'),
                ),
              TextButton(
                onPressed: () =>
                    muted ? vm.unmute(alert) : vm.mute(alert, const Duration(hours: 1)),
                child: Text(muted ? 'Unmute' : 'Mute 1h'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
