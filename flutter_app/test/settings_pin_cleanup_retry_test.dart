import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/domain/app_preferences.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/settings_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

class _DisablingSettings extends SettingsViewModel {
  _DisablingSettings(super.app);
  bool persisted = false;
  @override
  Future<void> start() async {}
  @override
  AppPreferences get saved => AppPreferences.defaults.copyWith(appLockEnabled: !persisted);
  @override
  bool get isDirty => !persisted;
  @override
  String? get status => persisted ? 'Settings saved.' : null;
  @override
  Future<void> save() async {
    persisted = true;
    notifyListeners();
  }
}

class _FailingPinCleanup extends AppLockController {
  _FailingPinCleanup(super.repository);
  int clearCalls = 0;
  bool removed = false;
  @override
  bool get hasStoredPin => !removed;
  @override
  Future<String?> verifyPinForSensitiveAction(String pin) async => null;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> clearPin() async {
    clearCalls++;
    if (clearCalls == 1) throw StateError('PIN cleanup failed');
    removed = true;
  }
}

void main() {
  testWidgets('Retry save completes pending PIN removal after preferences already persisted', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = AppRepository(db, SecretStore(storage: FakeSecureStorage({})));
    final app = AppState(repository);
    final settings = _DisablingSettings(app);
    final lock = _FailingPinCleanup(repository);
    final navigator = GlobalKey<NavigatorState>();
    Future<void>? saving;
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Finder key(String value) => find.byKey(ValueKey(value));
    try {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: app),
            ChangeNotifierProvider<SettingsViewModel>.value(value: settings),
            ChangeNotifierProvider<AppLockController>.value(value: lock),
          ],
          child: MaterialApp(
            navigatorKey: navigator,
            theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
            home: const Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 2; attempt++) {
        saving =
            Function.apply(tester.widget<FilledButton>(key('settings.save')).onPressed!, [])
                as Future<void>;
        await tester.pumpAndSettle();
        if (key('settings.appLockOff.confirm').evaluate().isNotEmpty) {
          await tester.tap(key('settings.appLockOff.confirm'));
          await tester.pumpAndSettle();
        }
        expect(key('sudoAuth.dialog'), findsOneWidget);
        await tester.enterText(key('sudoAuth.pin'), '4913');
        await tester.pumpAndSettle();
        await tester.tap(key('sudoAuth.confirm'));
        await tester.pumpAndSettle();
        await saving;
        if (attempt == 0) {
          expect(settings.saved.appLockEnabled, isFalse);
          expect(lock.hasStoredPin, isTrue);
          expect(find.textContaining('PIN cleanup failed'), findsOneWidget);
          expect(find.text('Retry save'), findsOneWidget);
        }
      }
      expect(lock.clearCalls, 2);
      expect(lock.hasStoredPin, isFalse);
      expect(find.text('Settings saved.'), findsOneWidget);
      expect(key('settings.save.error'), findsNothing);
    } finally {
      navigator.currentState?.popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
      await saving;
      await tester.pumpWidget(const SizedBox.shrink());
      lock.dispose();
      settings.dispose();
      app.dispose();
    }
  });
}
