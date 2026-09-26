import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/settings_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_lock_controller.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/settings_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

class _DelayedLock extends AppLockController {
  _DelayedLock(super.repository);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> refresh() async {
    started.complete();
    await release.future;
  }
}

class _PersistedSettings extends SettingsViewModel {
  _PersistedSettings(super.app);
  bool persisted = false;
  @override
  Future<void> start() async {}
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

void main() {
  for (final fail in [false, true]) {
    testWidgets('save waits for lock refresh and reports ${fail ? 'failure' : 'completion'}', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = AppRepository(db, SecretStore(storage: FakeSecureStorage({})));
      final app = AppState(repo);
      final vm = _PersistedSettings(app);
      final lock = _DelayedLock(repo);
      tester.view.physicalSize = const Size(1200, 4200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void>? saving;
      try {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: app),
              ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
              ChangeNotifierProvider<AppLockController>.value(value: lock),
            ],
            child: MaterialApp(
              theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
              home: const Scaffold(body: SettingsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('settings.save'));
        // Retain the actual async button operation so cleanup also waits after an assertion fails.
        saving = Function.apply(tester.widget<FilledButton>(button).onPressed!, []) as Future<void>;
        await tester.pump();
        expect(lock.started.isCompleted, isTrue);
        await tester.pump();
        expect(find.text('Saving…'), findsOneWidget);
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        expect(find.text('Settings saved.'), findsNothing);
        if (fail) {
          lock.release.completeError(StateError('lock refresh unavailable'));
        } else {
          lock.release.complete();
        }
        await tester.pump();
        await saving;
        await tester.pump();
        expect(find.text('Saving…'), findsNothing);
        expect(tester.takeException(), isNull);
        if (fail) {
          expect(find.textContaining('lock refresh unavailable'), findsOneWidget);
          expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
          expect(find.text('Settings saved.'), findsNothing);
        } else {
          expect(find.text('Settings saved.'), findsOneWidget);
        }
      } finally {
        if (!lock.release.isCompleted) lock.release.complete();
        await tester.pump();
        await saving;
        await tester.pumpWidget(const SizedBox.shrink());
        lock.dispose();
        vm.dispose();
        app.dispose();
      }
    });
  }
}
