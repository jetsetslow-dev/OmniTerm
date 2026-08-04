import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_database.dart';
import 'data/app_repository.dart';
import 'ui/app_scaffold.dart';
import 'ui/navigation.dart';
import 'ui/shell_state.dart';
import 'ui/view_model/app_state.dart';
import 'ui/view_model/monitor_view_model.dart';
import 'ui/view_model/servers_view_model.dart';
import 'ui/theme/theme.dart';

void main() {
  runApp(const OmniTermApp());
}

/// Root of the Flutter app, replacing `MainActivity` + `MyApplicationTheme`.
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
          create: (context) => AppState(AppRepository(context.read<AppDatabase>(), null))..start(),
        ),
        ChangeNotifierProxyProvider<AppState, ServersViewModel>(
          create: (context) => ServersViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? ServersViewModel(app),
        ),
        ChangeNotifierProxyProvider<AppState, MonitorViewModel>(
          create: (context) => MonitorViewModel(context.read<AppState>()),
          update: (_, app, previous) => previous ?? MonitorViewModel(app),
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
