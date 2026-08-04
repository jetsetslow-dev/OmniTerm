import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/script_presets.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/scripts_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/scripts_view_model.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late ScriptsViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await app.start();
    vm = ScriptsViewModel(app);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ScriptsViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: ScriptsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// See MIGRATION.md: cancelling a drift `watch` subscription schedules zero-duration timers, and
  /// the end-of-test check fails while any remain queued.
  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('both tabs are present and explain themselves', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('scripts.tab.quick')), findsOneWidget);
    expect(find.byKey(const ValueKey('scripts.tab.fleet')), findsOneWidget);
    expect(find.textContaining('run on the currently selected host'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
    await tester.pumpAndSettle();
    expect(find.textContaining('broadcast to several hosts'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('each tab offers its own preset family', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('scripts.presets.homelab')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scripts.presets.fleet')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the empty state points at both ways to get scripts', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('scripts.empty')), findsOneWidget);
    expect(find.textContaining('turn on the homelab presets'), findsOneWidget);
    await finish(tester);
  });

  group('preset toggles', () {
    testWidgets('enabling warns that it resets edits, then seeds', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('scripts.presets.homelab.switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('resets any edits'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('scripts.presets.cancel')));
      await tester.pumpAndSettle();
      expect(vm.allScripts, isEmpty, reason: 'cancelling must seed nothing');

      await tester.tap(find.byKey(const ValueKey('scripts.presets.homelab.switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scripts.presets.confirm')));
      await tester.pumpAndSettle();

      expect(vm.allScripts, hasLength(kHomelabPresets.length));
      expect(find.byKey(const ValueKey('scripts.list')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('disabling says the user\'s own scripts are kept', (tester) async {
      await pump(tester);
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('scripts.presets.homelab.switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your own scripts are kept'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scripts.presets.cancel')));
      await tester.pumpAndSettle();
      await finish(tester);
    });
  });

  group('the editor', () {
    testWidgets('creates a script and lists it under its category', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('scripts.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'Uptime');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.command')), 'uptime -p');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.category')), 'Health');
      await tester.tap(find.byKey(const ValueKey('scripts.editor.save')));
      await tester.pumpAndSettle();

      expect(find.text('Uptime'), findsOneWidget);
      expect(find.text('Health'), findsOneWidget);
      expect(find.text('uptime -p'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an incomplete script is refused inside the sheet', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('scripts.add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scripts.editor.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scripts.editor.error')), findsOneWidget);
      expect(vm.allScripts, isEmpty);
      await finish(tester);
    });

    testWidgets('adding from the Fleet tab defaults to a fleet command', (tester) async {
      // Adding from a list and having the result not appear in it would be baffling.
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('scripts.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'Broadcast');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.command')), 'uptime');
      await tester.tap(find.byKey(const ValueKey('scripts.editor.save')));
      await tester.pumpAndSettle();

      expect(vm.allScripts.single.availableForFleet, isTrue);
      expect(vm.allScripts.single.availableForQuick, isFalse);
      expect(find.text('Broadcast'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('editing a preset warns that re-enabling overwrites it', (tester) async {
      await pump(tester);
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await tester.pumpAndSettle();

      // Any pristine preset shows the note; tap whichever card is on screen.
      final card = find.byKey(ValueKey('scripts.card.${vm.allScripts.first.id}'));
      expect(card, findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scripts.editor.presetNote')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scripts.editor.close')));
      await tester.pumpAndSettle();
      await finish(tester);
    });
  });

  group('cards', () {
    testWidgets('an untouched preset is marked as one', (tester) async {
      await pump(tester);
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await tester.pumpAndSettle();

      expect(find.text('PRESET'), findsWidgets);
      await finish(tester);
    });

    testWidgets('a user script carries no preset badge', (tester) async {
      await pump(tester);
      await vm.saveScript(name: 'Mine', command: 'echo hi');
      await tester.pumpAndSettle();

      expect(find.text('PRESET'), findsNothing);
      await finish(tester);
    });

    testWidgets('deleting a preset says it can be brought back', (tester) async {
      // That changes whether the decision needs care, so it is worth saying.
      await pump(tester);
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await tester.pumpAndSettle();

      final preset = vm.allScripts.first;
      final deleteButton = find.byKey(ValueKey('scripts.card.${preset.id}.delete'));
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      expect(find.textContaining('bring it back with the toggle'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('scripts.delete.cancel')));
      await tester.pumpAndSettle();
      expect(vm.allScripts, hasLength(kHomelabPresets.length));
      await finish(tester);
    });

    testWidgets('deleting a user script says it is permanent', (tester) async {
      await pump(tester);
      await vm.saveScript(name: 'Mine', command: 'echo hi');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('scripts.card.${vm.allScripts.single.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('deleted permanently'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('scripts.delete.confirm')));
      await tester.pumpAndSettle();
      expect(vm.allScripts, isEmpty);
      await finish(tester);
    });
  });
}
