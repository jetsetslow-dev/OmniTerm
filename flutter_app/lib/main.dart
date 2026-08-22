import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'data/app_database.dart';
import 'data/app_repository.dart';
import 'data/shares/dart_smb_client.dart';
import 'data/shares/platform_smb_client.dart';
import 'data/shares/ftp_remote_fs_client.dart';
import 'data/shares/remote_fs_client.dart';
import 'data/shares/webdav_remote_fs_client.dart';
import 'data/ssh/dartssh_transport.dart';
import 'data/ssh/ssh_tunnel_manager.dart';
import 'data/ssh/secure_host_key_store.dart';
import 'data/ssh/ssh_host_key_trust.dart';
import 'data/ssh/ssh_transport.dart';
import 'domain/network_share_form.dart';
import 'domain/external_action_guard.dart';
import 'domain/external_ui_requests.dart';
import 'domain/server_credentials.dart';
import 'platform/alert_notifier.dart';
import 'platform/ads_controller.dart';
import 'platform/biometric_auth.dart';
import 'platform/battery_saver_controller.dart';
import 'domain/startup_recovery.dart';
import 'platform/crash_log.dart';
import 'platform/distribution.dart';
import 'platform/home_widget_sync.dart';
import 'platform/external_launch.dart';
import 'platform/license_controller.dart';
import 'platform/screen_security.dart';
import 'platform/shortcut_helper.dart';
import 'platform/platform_permissions.dart';
import 'platform/session_service.dart';
import 'ui/view_model/app_lock_controller.dart';
import 'ui/view_model/host_status_probe.dart';
import 'ui/view_model/tunnel_autostart.dart';
import 'ui/widgets/app_lock_gate.dart';
import 'ui/widgets/host_key_approval_host.dart';
import 'ui/widgets/navigation_guard_host.dart';
import 'ui/widgets/connection_prompt_host.dart';
import 'ui/app_scaffold.dart';
import 'domain/back_exit_policy.dart';
import 'ui/navigation.dart';
import 'ui/theme/colors.dart';
import 'ui/shell_state.dart';
import 'ui/view_model/app_state.dart';
import 'platform/legacy_secret_channel.dart';
import 'platform/secret_store.dart';
import 'ui/view_model/alerts_view_model.dart';
import 'ui/view_model/backup_view_model.dart';
import 'ui/view_model/auth_keys_view_model.dart';
import 'ui/view_model/fleet_view_model.dart';
import 'ui/view_model/health_scoring_view_model.dart';
import 'ui/view_model/infra_view_model.dart';
import 'ui/view_model/monitor_view_model.dart';
import 'ui/view_model/network_view_model.dart';
import 'ui/view_model/scripts_view_model.dart';
import 'ui/view_model/settings_view_model.dart';
import 'domain/alert_evaluation.dart';
import 'ui/view_model/telemetry_poller.dart';
import 'ui/view_model/shell_view_model.dart';
import 'ui/view_model/shares_view_model.dart';
import 'ui/view_model/sftp_view_model.dart';
import 'ui/view_model/servers_view_model.dart';
import 'ui/theme/theme.dart';
import 'ui/widgets/startup_recovery_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await installCrashHistory();

  // A startup crash used to kill the app before any UI existed, and the next launch did the same —
  // on a device the only escape was clearing app data, which throws away every saved host to get
  // past a problem the user cannot even see. Kotlin gates this the same way
  // (`MainActivity.kt:55`): a recent startup crash offers recovery instead of relaunching into it.
  final log = CrashLog.instance;
  final last = log.entries.isEmpty ? null : log.entries.first;
  final verdict = classifyStartupCrash(
    report: last?.report,
    recordedAtMs: last?.timeMs ?? 0,
    nowMs: DateTime.now().millisecondsSinceEpoch,
  );
  if (verdict == StartupCrashVerdict.offerRecovery && last!.startup) {
    runApp(StartupRecoveryApp(report: last.report));
    return;
  }

  try {
    runApp(const OmniTermApp());
  } catch (error, stack) {
    // Anything thrown while building the root is recorded as a *startup* crash, so the next launch
    // recognises it — and this one shows an explanation rather than a dead window.
    await log.record(error, stack, thread: 'Startup', startup: true);
    runApp(StartupRecoveryApp(report: '$error\n$stack'));
  }
}

/// Root of the Flutter app, replacing `MainActivity` + `MyApplicationTheme`.
/// Builds the repository with the Android bridge that reads Kotlin-era credentials attached.
///
/// Without it, every credential the old app saved would read back blank after an in-place upgrade.
/// The migration pass runs once here rather than lazily per read, so a user whose upgrade lands
/// mid-session does not find some hosts working and others not.
AppRepository _buildRepository(AppDatabase db) {
  final legacy = LegacySecretChannel();
  final repository = AppRepository(db, SecretStore(legacyDecryptor: legacy.decrypt));
  unawaited(repository.migrateLegacySecrets());
  return repository;
}

/// Builds the file client for one saved share.
///
/// The protocol decides the implementation, and only the two with a client are offered — the Shares
/// tab hides Browse for the rest rather than handing back a null the browser would have to explain
/// (§18). SMB goes through the native bridge (§7.1); SFTP reuses the same pooled transport every
/// other screen uses, so a share and a host on the same machine share one authenticated connection.
Future<RemoteFsClient?> Function(NetworkShare) _shareClientFor(DartSshTransport transport) =>
    (share) async {
      final protocol = ShareProtocol.fromId(share.protocol);
      return switch (protocol) {
        ShareProtocol.smb => () {
          final endpoint = SmbEndpoint(
            host: share.address,
            port: share.port,
            shareName: ShareClients.smbShareName(share) ?? share.sharePath,
            domain: share.workgroup,
            username: share.username,
            password: share.password,
            anonymous: share.anonymous,
          );
          return Platform.isAndroid ? PlatformSmbClient(endpoint) : DartSmbClient(endpoint);
        }(),
        ShareProtocol.sftp => transport.sftp(
          SshCredentials(
            host: share.address,
            port: share.port,
            username: share.username,
            password: share.password.isEmpty ? null : share.password,
          ),
        ),
        ShareProtocol.ftp => FtpRemoteFsClient(
          host: share.address,
          port: share.port,
          username: share.anonymous ? 'anonymous' : share.username,
          password: share.anonymous ? '' : share.password,
        ),
        ShareProtocol.webdav => WebDavRemoteFsClient(
          host: share.address,
          port: share.port,
          useHttps: share.useHttps,
          username: share.anonymous ? '' : share.username,
          password: share.anonymous ? '' : share.password,
        ),
        _ => null,
      };
    };

/// Builds the SFTP client for one host.
///
/// Resolved per call rather than cached, because a host's key or credential profile can be changed
/// from the Hosts screen while the SFTP screen is open, and a stale client would keep authenticating
/// with the credentials the app happened to start with.
Future<RemoteFsClient?> Function(Server) _sftpFor(
  DartSshTransport transport,
  AppRepository repository,
) => (server) async {
  try {
    return transport.sftp(
      resolveCredentials(
        server,
        keys: await repository.getAllKeys(),
        profiles: await repository.getAllProfiles(),
      ),
    );
  } on CredentialResolutionException {
    // The view model reports "unavailable" for a null client, which is the honest outcome for a
    // host whose key has been deleted. Throwing here would surface as an unhandled error
    // instead of a message the user can act on.
    return null;
  }
};

class OmniTermApp extends StatelessWidget {
  const OmniTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NavigationController()),
        Provider<LicenseController>(
          create: (_) {
            final controller = isPlayStoreDistribution
                ? InAppLicenseController()
                : DisabledLicenseController();
            controller.start();
            return controller;
          },
          dispose: (_, controller) => controller.dispose(),
        ),
        Provider<AdsController>(
          create: (_) => AdsController(enabled: isPlayStoreDistribution)..start(),
          dispose: (_, controller) => controller.dispose(),
        ),
        Provider<HomeWidgetSync>(create: (_) => HomeWidgetSync()),
        Provider<ExternalActionGuard>(create: (_) => ExternalActionGuard()),
        Provider<ExternalLaunch>(create: (_) => ExternalLaunch()),
        Provider<ShortcutHelper>(create: (_) => ShortcutHelper()),
        Provider<PlatformPermissions>(create: (_) => PlatformPermissions()),
        ChangeNotifierProvider<ExternalUiRequests>(create: (_) => ExternalUiRequests()),
        ChangeNotifierProvider(
          create: (_) =>
              ShellState(keepScreenOnSetter: (enabled) => WakelockPlus.toggle(enable: enabled)),
        ),
        // One database and repository for the app's lifetime; the ViewModels layer on top.
        Provider<AppDatabase>(create: (_) => AppDatabase(), dispose: (_, db) => db.close()),
        // One trust store and one transport for the whole app. Sharing them is what makes the
        // connection pool, the host-key pins and the approval prompt consistent across screens —
        // a per-screen transport would re-prompt for the same host on every tab.
        Provider<SshHostKeyTrust>(create: (_) => SshHostKeyTrust(SecureHostKeyStore())),
        Provider<DartSshTransport>(
          create: (context) => DartSshTransport(context.read<SshHostKeyTrust>()),
          dispose: (_, transport) => transport.shutdown(),
        ),
        ProxyProvider<DartSshTransport, SshTransport>(update: (_, transport, _) => transport),
        // A tunnel's connection is its own: `openDedicatedClient` stays out of the session pool, so
        // a forward does not die when the last terminal on that host is closed.
        Provider<SshTunnelManager>(
          create: (context) =>
              SshTunnelManager(context.read<DartSshTransport>().openDedicatedClient),
          dispose: (_, manager) => manager.stopAll(),
        ),
        Provider<ScreenSecurity>(create: (_) => ScreenSecurity()),
        ChangeNotifierProvider<AppState>(
          create: (context) => AppState(_buildRepository(context.read<AppDatabase>()))..start(),
        ),
        // Nothing else keeps `status` current, and Monitor, Infra, Fleet, SFTP and the terminal all
        // offer only hosts that are online — so without this sweep the app reads as empty
        // everywhere (§15.8).
        // Same reason as the probe below: nothing reads this, so without `lazy: false` the tunnels
        // marked "start when OmniTerm opens" would never start.
        Provider<TunnelAutoStarter>(
          lazy: false,
          create: (context) => TunnelAutoStarter(
            context.read<AppState>().repository,
            context.read<SshTunnelManager>(),
            trust: context.read<SshHostKeyTrust>(),
          )..start(),
        ),
        ChangeNotifierProvider<HostStatusProbe>(
          // `lazy: false` matters: nothing in the widget tree reads this provider, so with the
          // default it would never be constructed and the sweep would never run.
          lazy: false,
          create: (context) => HostStatusProbe(
            context.read<AppState>().repository,
            transport: context.read<SshTransport>(),
          )..start(),
        ),
        // Declared after AppState because it reads the same repository, and loaded eagerly: the
        // lock has to be up before the first frame, not after it.
        ChangeNotifierProvider<AppLockController>(
          create: (context) => AppLockController(
            context.read<AppState>().repository,
            biometricPrompt: BiometricAuth().prompt,
            biometricAvailability: BiometricAuth().isAvailable,
          )..load(),
        ),
        Provider<AlertNotifier>(create: (_) => LocalAlertNotifier()),
        ChangeNotifierProxyProvider<AppState, AlertsViewModel>(
          create: (context) =>
              AlertsViewModel(context.read<AppState>(), notifier: context.read<AlertNotifier>()),
          update: (_, app, previous) => previous!,
        ),
        // Declared after the alerts view model because it feeds it: the poller measures hosts, and
        // something has to decide what a measurement means. Still `lazy: false` — nothing in the
        // widget tree reads this provider, so without it the loop would never start.
        ChangeNotifierProvider<TelemetryPoller>(
          lazy: false,
          create: (context) {
            final alerts = context.read<AlertsViewModel>();
            return TelemetryPoller(
              context.read<AppState>(),
              transport: context.read<SshTransport>(),
              // Alert rules, the evaluation and the notifier were all ported and tested, and
              // nothing ever called them — every configured rule sat inert. This is the call the
              // evaluation's own doc comment says exists.
              onSample: (server, metrics) => alerts.evaluate(
                server,
                AlertSample(
                  cpuPercent: metrics.cpuPercent,
                  memoryPercent: metrics.memPercent,
                  diskPercent: metrics.diskPercent,
                  latencyMs: server.lastLatency,
                  mounts: metrics.disks,
                  cpuTempC: metrics.cpuTempC,
                ),
              ),
            )..start();
          },
        ),
        ChangeNotifierProxyProvider<AppState, ServersViewModel>(
          create: (context) => ServersViewModel(
            context.read<AppState>(),
            transport: context.read<SshTransport>(),
            shortcuts: context.read<ShortcutHelper>(),
          ),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, MonitorViewModel>(
          create: (context) => MonitorViewModel(
            context.read<AppState>(),
            transport: context.read<SshTransport>(),
            poller: context.read<TelemetryPoller>(),
          ),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, InfraViewModel>(
          create: (context) =>
              InfraViewModel(context.read<AppState>(), transport: context.read<SshTransport>()),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, FleetViewModel>(
          create: (context) => FleetViewModel(
            context.read<AppState>(),
            transport: context.read<SshTransport>(),
            poller: context.read<TelemetryPoller>(),
          ),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, SftpViewModel>(
          create: (context) => SftpViewModel(
            context.read<AppState>(),
            fsClientFor: _sftpFor(
              context.read<DartSshTransport>(),
              context.read<AppState>().repository,
            ),
            shareClientFor: _shareClientFor(context.read<DartSshTransport>()),
            // A shell, for the questions SFTP itself cannot answer — currently `du`.
            transport: context.read<SshTransport>(),
          ),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, SharesViewModel>(
          create: (context) => SharesViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, AuthKeysViewModel>(
          create: (context) => AuthKeysViewModel(
            context.read<AppState>(),
            hostKeyTrust: context.read<SshHostKeyTrust>(),
          ),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<AppState, ScriptsViewModel>(
          create: (context) => ScriptsViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? ScriptsViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, NetworkViewModel>(
          create: (context) =>
              NetworkViewModel(context.read<AppState>(), tunnels: context.read<SshTunnelManager>()),
          update: (_, app, previous) => previous ?? NetworkViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, BackupViewModel>(
          create: (context) => BackupViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? BackupViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, HealthScoringViewModel>(
          create: (context) => HealthScoringViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? HealthScoringViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, ShellViewModel>(
          create: (context) => ShellViewModel(
            context.read<AppState>(),
            transport: context.read<SshTransport>(),
            sessionService: SessionService(),
            // Read once: the probe provider is eager and outlives this view model.
            hasProbed: context.read<HostStatusProbe>().hasProbed,
            markReachable: context.read<HostStatusProbe>().markReachable,
            syncLiveSessionServers: context.read<HostStatusProbe>().setLiveSessionServers,
            shortcuts: context.read<ShortcutHelper>(),
          ),
          update: (_, app, previous) => previous!,
        ),
        ChangeNotifierProvider<BatterySaverController>(
          lazy: false,
          create: (context) => BatterySaverController(
            context.read<AppState>(),
            context.read<ShellState>(),
            context.read<TelemetryPoller>(),
            context.read<ShellViewModel>(),
          )..start(),
        ),
        ChangeNotifierProxyProvider<AppState, SettingsViewModel>(
          // Eager: theme/text scale/security-sensitive settings must apply before the user ever
          // opens Settings. The previous lazy provider left every launch on defaults until that
          // screen happened to be visited.
          lazy: false,
          create: (context) => SettingsViewModel(context.read<AppState>())..start(),
          update: (_, app, previous) => previous ?? SettingsViewModel(app),
        ),
      ],
      child: Builder(
        builder: (context) {
          final prefs = context.watch<SettingsViewModel>().saved;
          final brightness = MediaQuery.platformBrightnessOf(context);
          final isDark = prefs.darkMode ?? (brightness == Brightness.dark);
          final mode = themeModeFor(
            isDark: isDark,
            highContrast: prefs.accessibility,
            amoled: prefs.amoled,
          );
          return MaterialApp(
            title: 'OmniTerm',
            debugShowCheckedModeBanner: false,
            theme: omniTheme(mode, brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(prefs.textScalePercent / 100.0)),
              child: child!,
            ),
            // The lock is the outermost wrapper: a gate with a route, tab or dialog reachable
            // around it is decoration. The host-key prompt sits inside it, so a locked app can
            // never be made to show one.
            home: AppLockGate(
              controller: context.read<AppLockController>(),
              // The host-key prompt sits inside the lock and above every screen: a first-contact
              // host can be met from the terminal, the monitor poller, SFTP or a connection test.
              child: HostKeyApprovalHost(
                trust: context.read<SshHostKeyTrust>(),
                child: const _RuntimeBindings(
                  child: _ScreenSecurityBinding(
                    child: _BackHandler(
                      // Above every screen for the same reason as the host-key prompt: a host is
                      // connected from the host list, the Infra tab, a shortcut and a quick action
                      // too, not only from the terminal.
                      child: ConnectionPromptHost(
                        child: NavigationGuardHost(child: AppCoreScaffold()),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Keeps platform services and the small scaffold state connected to the feature ViewModels.
///
/// These listeners are eager and app-wide because badges, entitlements, widgets and wakelock are
/// app-wide facts. Wiring them in an individual screen made each integration appear implemented
/// while remaining dormant until that screen happened to be opened.
class _RuntimeBindings extends StatefulWidget {
  const _RuntimeBindings({required this.child});

  final Widget child;

  @override
  State<_RuntimeBindings> createState() => _RuntimeBindingsState();
}

class _RuntimeBindingsState extends State<_RuntimeBindings> with WidgetsBindingObserver {
  LicenseController? _license;
  AppState? _app;
  AlertsViewModel? _alerts;
  AppLockController? _lock;
  NavigationController? _navigation;
  StreamSubscription<Uri?>? _widgetClicks;
  StreamSubscription<ExternalAction>? _externalActions;
  bool _initialWidgetRead = false;
  bool _initialExternalRead = false;
  bool _drainingExternalActions = false;
  bool _runtimeSyncScheduled = false;
  bool? _lastKeepScreenOnDefault;
  List<String> _lastWidgetServerState = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final license = context.read<LicenseController>();
    if (!identical(_license, license)) {
      _license?.state.removeListener(_syncLicense);
      _license = license;
      license.state.addListener(_syncLicense);
      _scheduleRuntimeSync();
    }

    final app = context.read<AppState>();
    if (!identical(_app, app)) {
      _app?.removeListener(_syncApp);
      _app = app;
      app.addListener(_syncApp);
      _scheduleRuntimeSync();
    }

    final alerts = context.read<AlertsViewModel>();
    if (!identical(_alerts, alerts)) {
      _alerts?.removeListener(_syncAlerts);
      _alerts = alerts;
      alerts.addListener(_syncAlerts);
      unawaited(alerts.start());
      _scheduleRuntimeSync();
    }

    final lock = context.read<AppLockController>();
    if (!identical(_lock, lock)) {
      _lock?.removeListener(_consumeExternalAction);
      _lock = lock;
      lock.addListener(_consumeExternalAction);
      _scheduleRuntimeSync();
    }
    final navigation = context.read<NavigationController>();
    if (!identical(_navigation, navigation)) {
      _navigation?.removeListener(_syncNavigation);
      _navigation = navigation;
      navigation.addListener(_syncNavigation);
      _scheduleRuntimeSync();
    }

    _widgetClicks ??= context.read<HomeWidgetSync>().widgetClickedStream.listen(_handleWidgetUri);
    if (!_initialWidgetRead) {
      _initialWidgetRead = true;
      unawaited(context.read<HomeWidgetSync>().getInitiallyLaunchedUri().then(_handleWidgetUri));
    }
    _externalActions ??= context.read<ExternalLaunch>().actions.listen(_queueExternalAction);
    if (!_initialExternalRead) {
      _initialExternalRead = true;
      unawaited(
        context.read<ExternalLaunch>().takeInitialActions().then((actions) {
          for (final action in actions) {
            _queueExternalAction(action);
          }
        }),
      );
    }
  }

  /// Provider is still mounting ancestors when [didChangeDependencies] first runs. Notifying one
  /// of those ancestors synchronously is illegal and used to make a cold device launch report
  /// `markNeedsBuild during build` on whichever screen happened to be selected. Coalesce all
  /// initial bindings at the first safe frame boundary; later listener-driven updates still run
  /// immediately.
  void _scheduleRuntimeSync() {
    if (_runtimeSyncScheduled) return;
    _runtimeSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runtimeSyncScheduled = false;
      if (!mounted) return;
      if (_license != null) _syncLicense();
      if (_app != null) _syncApp();
      if (_alerts != null) _syncAlerts();
      if (_lock != null) _consumeExternalAction();
      if (_navigation != null) _syncNavigation();
    });
  }

  void _syncLicense() {
    final state = _license!.state.value;
    final shell = context.read<ShellState>();
    shell.updateLicenseEntitlement(
      enabled: state.enabled,
      resolved: !state.loading,
      unlocked: state.unlocked,
      adsRemoved: state.adsRemoved,
    );
    shell.reconcileHostLimit(
      _app?.servers.length ?? 0,
      reason:
          'Your full unlock is no longer active. Choose the one saved host to keep in the free '
          'Play Store build.',
    );
  }

  void _syncApp() {
    final app = _app!;
    context.read<ShellState>().reconcileHostLimit(app.servers.length);
    final keepOn = app.preferences.keepScreenOn;
    if (_lastKeepScreenOnDefault != keepOn) {
      _lastKeepScreenOnDefault = keepOn;
      context.read<ShellState>().setKeepScreenOnDirect(keepOn);
    }
    final state = app.servers
        .map(
          (server) =>
              '${server.id}\u0000${server.name}\u0000${server.host}\u0000${server.status}\u0000${server.healthScore}',
        )
        .toList(growable: false);
    if (!_sameValues(state, _lastWidgetServerState)) {
      _lastWidgetServerState = state;
      unawaited(context.read<HomeWidgetSync>().updateWidgetData(app.servers));
    }
    _consumeExternalAction();
  }

  void _syncAlerts() {
    final alerts = _alerts!;
    context.read<ShellState>().updateVisibleAlertCount(
      alerts.alertsEnabled ? alerts.unmutedCount : 0,
    );
  }

  void _handleWidgetUri(Uri? uri) {
    if (uri == null || !mounted) return;
    final segments = uri.pathSegments;
    final serverIndex = segments.indexOf('server');
    final serverId = serverIndex >= 0 && serverIndex + 1 < segments.length
        ? int.tryParse(segments[serverIndex + 1])
        : int.tryParse(uri.queryParameters['server_id'] ?? '');
    _queueExternalAction(
      ExternalAction(
        id: uri.toString(),
        type: segments.contains('refresh')
            ? 'refresh_servers'
            : (serverId == null ? 'open_servers' : 'connect_server'),
        targetId: serverId,
        uri: uri,
      ),
    );
  }

  void _queueExternalAction(ExternalAction action) {
    if (!mounted) return;
    context.read<ExternalActionGuard>().setPendingAction(action);
    _consumeExternalAction();
  }

  void _consumeExternalAction() {
    if (!mounted || _lock == null || _app == null || _drainingExternalActions) {
      return;
    }
    // Both loads are authoritative. Their pre-load defaults are deliberately permissive for
    // rendering, so treating those defaults as security state would let a cold-start shortcut run
    // for a few frames before the stored app-lock setting arrived.
    if (!_lock!.isLoaded || !_app!.isLoaded || _lock!.isLocked) return;
    _drainingExternalActions = true;
    unawaited(_drainExternalActions());
  }

  Future<void> _drainExternalActions() async {
    final guard = context.read<ExternalActionGuard>();
    try {
      while (mounted && _lock!.isLoaded && !_lock!.isLocked && _app!.isLoaded) {
        final action = guard.tryConsume(isAppLocked: false);
        if (action == null) break;
        await _executeExternalAction(action);
      }
    } finally {
      _drainingExternalActions = false;
    }
  }

  /// Says a shortcut's target is gone, rather than redirecting in silence.
  ///
  /// Ported from `shortcutTargetMissingToast` (`ui/AppViewModel.kt:4537`). Landing on the host list
  /// with no explanation reads as the shortcut having done nothing, or having gone to the wrong
  /// place — both of which invite the user to try it again.
  void _reportMissingShortcutTarget(String noun) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        key: const ValueKey('shortcut.targetMissing'),
        content: Text('That $noun no longer exists.'),
      ),
    );
  }

  Future<void> _executeExternalAction(ExternalAction action) async {
    final nav = context.read<NavigationController>();
    final shell = context.read<ShellViewModel>();
    final sftp = context.read<SftpViewModel>();
    final uiRequests = context.read<ExternalUiRequests>();
    switch (action.type) {
      case 'connect_server':
        // The repository, not `_app.servers`. On a cold start from a launcher shortcut the host
        // stream may not have emitted yet, so the in-memory list is empty and a perfectly good
        // shortcut looked like a deleted host. Kotlin reads the row directly for the same reason
        // (`ui/AppViewModel.kt:4533`).
        final targetId = action.targetId;
        final server = targetId == null ? null : await _app!.repository.getServerById(targetId);
        if (server == null) {
          _reportMissingShortcutTarget('host');
          nav.navigateTo(Screen.servers);
          return;
        }
        _app!.selectedServerId = server.id;
        nav.navigateTo(Screen.shell);
        await shell.connect(server, controlMode: shell.useControlMode);
      case 'open_split':
        final firstId = action.targetId;
        final secondId = action.secondTargetId;
        final first = firstId == null ? null : await _app!.repository.getServerById(firstId);
        final second = secondId == null ? null : await _app!.repository.getServerById(secondId);
        if (first == null || second == null) {
          _reportMissingShortcutTarget('host');
          nav.navigateTo(Screen.servers);
          return;
        }
        nav.navigateTo(Screen.shell);
        final beforeFirst = shell.sessions.map((session) => session.id).toSet();
        await shell.connect(first, controlMode: shell.useControlMode);
        final firstSession = shell.sessions.where((s) => !beforeFirst.contains(s.id)).firstOrNull;
        final beforeSecond = shell.sessions.map((session) => session.id).toSet();
        await shell.connect(second, controlMode: shell.useControlMode);
        final secondSession = shell.sessions.where((s) => !beforeSecond.contains(s.id)).firstOrNull;
        if (firstSession != null && secondSession != null) {
          shell.select(firstSession.id);
          shell.splitWith(secondSession.id);
        }
      case 'resume_session':
        final id = action.target;
        if (id != null && shell.sessions.any((session) => session.id == id)) {
          shell.select(id);
          nav.navigateTo(Screen.shell);
        }
      case 'open_share':
        final shares = await _app!.repository.getAllNetworkShares();
        final share = shares.where((row) => row.id == action.targetId).firstOrNull;
        if (share == null) {
          _reportMissingShortcutTarget('network share');
          nav.navigateTo(Screen.sftp);
          return;
        }
        nav.navigateTo(Screen.sftp);
        await sftp.openShare(share);
      case 'add_server':
        nav.navigateTo(Screen.servers);
        uiRequests.requestAddServer();
      case 'refresh_servers':
        nav.navigateTo(Screen.servers);
        final probe = context.read<HostStatusProbe>();
        final poller = context.read<TelemetryPoller>();
        await probe.sweep();
        await poller.cycle();
      case 'open_sftp':
        nav.navigateTo(Screen.sftp);
      case 'open_network':
        nav.navigateTo(Screen.network);
      case 'open_servers':
      default:
        nav.navigateTo(Screen.servers);
    }
  }

  void _syncNavigation() {
    context.read<ShellViewModel>().setTerminalVisible(_navigation!.currentScreen == Screen.shell);
  }

  static bool _sameValues(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _license?.onResume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _license?.state.removeListener(_syncLicense);
    _app?.removeListener(_syncApp);
    _alerts?.removeListener(_syncAlerts);
    _lock?.removeListener(_consumeExternalAction);
    _navigation?.removeListener(_syncNavigation);
    _widgetClicks?.cancel();
    _externalActions?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Applies (or lifts) the screenshot block whenever the preference changes.
///
/// A widget rather than a one-off call at startup, so toggling the setting takes effect at once —
/// a protection that only applies after a restart is one the user will believe they have when they
/// do not.
class _ScreenSecurityBinding extends StatefulWidget {
  const _ScreenSecurityBinding({required this.child});

  final Widget child;

  @override
  State<_ScreenSecurityBinding> createState() => _ScreenSecurityBindingState();
}

class _ScreenSecurityBindingState extends State<_ScreenSecurityBinding> {
  bool? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wanted = context.watch<AppState>().flagSecure;
    if (wanted == _applied) return;
    _applied = wanted;
    unawaited(context.read<ScreenSecurity>().setSecure(secure: wanted));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Routes the system back gesture through [NavigationController.navigateBack] so the screen
/// history — and the guards that can intercept a back press — behave as they did on Android.
///
/// At the root it also reproduces Kotlin's two guards (`ui/AppUi.kt:482`), which the first port
/// dropped: back is the easiest gesture on a phone to hit by accident, and this app's version of
/// "exit" drops live SSH sessions. One press warns; a second within two seconds leaves, or asks
/// first when something is still connected.
class _BackHandler extends StatefulWidget {
  const _BackHandler({required this.child});

  final Widget child;

  @override
  State<_BackHandler> createState() => _BackHandlerState();
}

class _BackHandlerState extends State<_BackHandler> {
  DateTime? _lastBackPress;

  bool get _hasLiveSessions =>
      context.read<ShellViewModel>().sessions.any((session) => session.isOpen);

  Future<void> _handleRootBack() async {
    final since = _lastBackPress;
    final action = decideBackExit(
      msSinceLastBackPress: since == null ? null : DateTime.now().difference(since).inMilliseconds,
      hasLiveSessions: _hasLiveSessions,
    );

    switch (action) {
      case BackExitAction.warn:
        _lastBackPress = DateTime.now();
        if (!mounted) return;
        // Kotlin shows a Toast; a SnackBar is this platform's equivalent, and it must not outlive
        // the window it describes or it would still be on screen after the press stopped counting.
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              key: ValueKey('app.backToExit'),
              content: Text('Press back again to exit'),
              duration: Duration(milliseconds: backExitDoublePressWindowMs),
            ),
          );
      case BackExitAction.exit:
        _lastBackPress = null;
        await SystemNavigator.pop();
      case BackExitAction.confirm:
        // Consumed either way: leaving it armed would let a Cancel be followed by a bare back press
        // that exits without asking again.
        _lastBackPress = null;
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: const ValueKey('app.exitDialog'),
            title: const Text('Exit OmniTerm?'),
            content: const Text('Exiting will terminate all active background SSH sessions.'),
            actions: [
              TextButton(
                key: const ValueKey('app.exitDialog.cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('app.exitDialog.confirm'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Terminate & Exit', style: TextStyle(color: OmniColors.red)),
              ),
            ],
          ),
        );
        if (confirmed == true) await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Never popped by the platform: every root-level exit goes through the guards above.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (context.read<NavigationController>().navigateBack()) return;
        unawaited(_handleRootBack());
      },
      child: widget.child,
    );
  }
}
