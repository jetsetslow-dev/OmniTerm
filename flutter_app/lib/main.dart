import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_database.dart';
import 'data/app_repository.dart';
import 'ui/app_scaffold.dart';
import 'ui/navigation.dart';
import 'ui/shell_state.dart';
import 'ui/view_model/app_state.dart';
import 'platform/legacy_secret_channel.dart';
import 'platform/secret_store.dart';
import 'ui/view_model/alerts_view_model.dart';
import 'ui/view_model/backup_view_model.dart';
import 'ui/view_model/auth_keys_view_model.dart';
import 'ui/view_model/fleet_view_model.dart';
import 'ui/view_model/infra_view_model.dart';
import 'ui/view_model/monitor_view_model.dart';
import 'ui/view_model/network_view_model.dart';
import 'ui/view_model/scripts_view_model.dart';
import 'ui/view_model/sftp_view_model.dart';
import 'ui/view_model/servers_view_model.dart';
import 'ui/theme/theme.dart';

void main() {
  runApp(const OmniTermApp());
}

/// Root of the Flutter app, replacing `MainActivity` + `MyApplicationTheme`.
/// Builds the repository with the Android bridge that reads Kotlin-era credentials attached.
///
/// Without it, every credential the old app saved would read back blank — see MIGRATION.md §7.10.
/// The migration pass runs once here rather than lazily per read, so a user whose upgrade lands
/// mid-session does not find some hosts working and others not.
AppRepository _buildRepository(AppDatabase db) {
  final legacy = LegacySecretChannel();
  final repository = AppRepository(
    db,
    SecretStore(legacyDecryptor: legacy.decrypt),
  );
  unawaited(repository.migrateLegacySecrets());
  return repository;
}

class OmniTermApp extends StatelessWidget {
  const OmniTermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NavigationController()),
        ChangeNotifierProvider(create: (_) => ShellState()),
        // One database and repository for the app's lifetime; the ViewModels layer on top.
        Provider<AppDatabase>(create: (_) => AppDatabase(), dispose: (_, db) => db.close()),
        ChangeNotifierProvider<AppState>(
          create: (context) => AppState(_buildRepository(context.read<AppDatabase>()))..start(),
        ),
        ChangeNotifierProxyProvider<AppState, ServersViewModel>(
          create: (context) => ServersViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? ServersViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, MonitorViewModel>(
          create: (context) => MonitorViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? MonitorViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, InfraViewModel>(
          create: (context) => InfraViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? InfraViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, FleetViewModel>(
          create: (context) => FleetViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? FleetViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, SftpViewModel>(
          create: (context) => SftpViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? SftpViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, AuthKeysViewModel>(
          create: (context) => AuthKeysViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? AuthKeysViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, ScriptsViewModel>(
          create: (context) => ScriptsViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? ScriptsViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, AlertsViewModel>(
          create: (context) => AlertsViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? AlertsViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, NetworkViewModel>(
          create: (context) => NetworkViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? NetworkViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, BackupViewModel>(
          create: (context) => BackupViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? BackupViewModel(app),
        ),
      ],
      child: Builder(
        builder: (context) {
          // TODO(migration): theme mode and font scale come from app_settings once the Drift
          // data layer lands (MIGRATION.md §3.2); the legacy default is the dark scheme.
          const mode = OmniThemeMode.dark;
          final brightness = MediaQuery.platformBrightnessOf(context);
          return MaterialApp(
            title: 'OmniTerm',
            debugShowCheckedModeBanner: false,
            theme: omniTheme(mode, brightness),
            home: const _BackHandler(child: AppCoreScaffold()),
          );
        },
      ),
    );
  }
}

/// Routes the system back gesture through [NavigationController.navigateBack] so the screen
/// history — and the guards that can intercept a back press — behave as they did on Android.
class _BackHandler extends StatelessWidget {
  const _BackHandler({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    return PopScope(
      // Only let the platform pop the app when the in-app stack is exhausted.
      canPop: nav.screenHistory.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) nav.navigateBack();
      },
      child: child,
    );
  }
}
