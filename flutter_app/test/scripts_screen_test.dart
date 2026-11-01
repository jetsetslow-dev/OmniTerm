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
import 'package:omniterm/ui/widgets/script_editor_dialog.dart';
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

  /// Cancelling a drift `watch` subscription schedules zero-duration timers, and
  /// the end-of-test check fails while any remain queued.
  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> openAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('scripts.add')));
    await tester.pumpAndSettle();
  }

  Future<void> tapInDialog(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('both tabs are present and explain themselves in Kotlin words', (tester) async {
    await pump(tester);
    expect(find.text('Scripts'), findsOneWidget);
    expect(find.text('Quick scripts'), findsOneWidget);
    expect(find.text('Fleet commands'), findsOneWidget);
    expect(
      find.text(
        'Quick scripts run on the currently selected host and can be filtered by OS or platform.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Fleet commands are broadcast commands for multiple hosts or groups from the Fleet screen.',
      ),
      findsOneWidget,
    );
    await finish(tester);
  });

  testWidgets('each tab offers its own preset family', (tester) async {
    await pump(tester);
    expect(find.text('Homelab preset scripts'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
    await tester.pumpAndSettle();
    expect(find.text('Fleet default commands'), findsOneWidget);
    await finish(tester);
  });

  group('preset toggles', () {
    testWidgets('enabling asks first with Kotlin wording, then seeds', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('scripts.presets.homelab.switch')));
      await tester.pumpAndSettle();
      expect(find.text('Enable preset scripts?'), findsOneWidget);
      expect(find.textContaining('resetting any earlier edits to them'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('scripts.presets.cancel')));
      await tester.pumpAndSettle();
      expect(vm.allScripts, isEmpty);

      await tester.tap(find.byKey(const ValueKey('scripts.presets.homelab.switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scripts.presets.confirm')));
      await tester.pumpAndSettle();
      expect(vm.allScripts, isNotEmpty);
      await finish(tester);
    });

    testWidgets('disabling fleet defaults says your own commands are kept', (tester) async {
      await pump(tester);
      await vm.setPresetsEnabled(fleet: true, enabled: true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('scripts.presets.fleet.switch')));
      await tester.pumpAndSettle();
      expect(find.text('Disable fleet defaults?'), findsOneWidget);
      expect(find.textContaining('Your own commands are kept.'), findsOneWidget);
      await finish(tester);
    });
  });

  group('the editor', () {
    testWidgets('adds a script with Kotlin defaults and lists it in the grid', (tester) async {
      await pump(tester);
      await openAdd(tester);

      expect(find.text('Add script'), findsOneWidget);
      expect(find.text('CMD'), findsOneWidget, reason: 'Kotlin pre-fills the shortcut label');
      final save = find.byKey(const ValueKey('scripts.editor.save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'Uptime');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.command')), 'uptime');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.category')), 'Ops');
      await tester.pumpAndSettle();
      await tapInDialog(tester, save);

      final saved = vm.allScripts.single;
      expect(saved.emoji, 'CMD');
      expect(saved.color, 'cyan');
      expect(saved.availableForQuick, isTrue);
      expect(saved.availableForFleet, isFalse);
      expect(find.byKey(const ValueKey('scripts.group.Ops')), findsOneWidget);
      expect(find.text('CMD Uptime'), findsOneWidget);
      expect(find.text('Quick'), findsWidgets);
      await finish(tester);
    });

    testWidgets('the shortcut label is upper-cased and capped at six', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.emoji')), 'restart!');
      await tester.pumpAndSettle();
      expect(find.text('RESTAR'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a script offered nowhere cannot be saved', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'x');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.command')), 'true');
      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.quick')));

      final save = find.byKey(const ValueKey('scripts.editor.save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await finish(tester);
    });

    testWidgets('adding from the Fleet tab defaults to a Fleet command', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('scripts.tab.fleet')));
      await tester.pumpAndSettle();
      await openAdd(tester);

      expect(find.text('Fleet'), findsWidgets);
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'Disk');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.command')), 'df -h');
      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.save')));

      final saved = vm.allScripts.single;
      expect(saved.category, 'Fleet');
      expect(saved.availableForFleet, isTrue);
      expect(saved.availableForQuick, isFalse);
      await finish(tester);
    });

    testWidgets('cancelling with edits asks before discarding them', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'half typed');
      await tester.pumpAndSettle();

      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.cancel')));
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scripts.editor.discard.cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scripts.editor')), findsOneWidget);

      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.cancel')));
      await tester.tap(find.byKey(const ValueKey('scripts.editor.discard.confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scripts.editor')), findsNothing);
      expect(vm.allScripts, isEmpty);
      await finish(tester);
    });

    testWidgets('an untouched editor closes without asking', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.cancel')));
      expect(find.byKey(const ValueKey('scripts.editor')), findsNothing);
      await finish(tester);
    });

    testWidgets('targets can be picked from Kotlin option menus', (tester) async {
      await pump(tester);
      await openAdd(tester);
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'Proxmox backup');
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.command')), 'vzdump');

      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.targetOs.menu')));
      await tester.tap(find.text('Linux').last);
      await tester.pumpAndSettle();
      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.targetSystem.menu')));
      await tester.tap(find.text('Proxmox').last);
      await tester.pumpAndSettle();
      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.save')));

      final saved = vm.allScripts.single;
      expect(saved.targetOs, 'Linux');
      expect(saved.targetSystem, 'Proxmox');
      expect(find.text('Linux'), findsOneWidget, reason: 'targeting is tagged on the card');
      expect(find.text('Proxmox'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('editing keeps colour and targeting and says Save changes', (tester) async {
      await pump(tester);
      await vm.saveScript(
        name: 'Mac only',
        command: 'sw_vers',
        color: 'amber',
        longRunning: true,
        targetOs: 'Darwin',
      );
      await tester.pumpAndSettle();
      final id = vm.allScripts.single.id;

      await tester.tap(find.byKey(ValueKey('scripts.card.$id.edit')));
      await tester.pumpAndSettle();
      expect(find.text('Edit script'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'macOS only');
      await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.save')));

      final saved = vm.allScripts.single;
      expect(saved.name, 'macOS only');
      expect(saved.color, 'amber');
      expect(saved.longRunning, isTrue);
      expect(saved.targetOs, 'Darwin');
      await finish(tester);
    });
  });

  group('cards', () {
    testWidgets('a long press opens the editor too', (tester) async {
      await pump(tester);
      await vm.saveScript(name: 'Load', command: 'uptime');
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(ValueKey('scripts.card.${vm.allScripts.single.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Edit script'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('scripts sit two to a row', (tester) async {
      await pump(tester);
      await vm.saveScript(name: 'One', command: 'a');
      await vm.saveScript(name: 'Two', command: 'b');
      await vm.saveScript(name: 'Three', command: 'c');
      await tester.pumpAndSettle();
      final ids = [for (final s in vm.allScripts) s.id];
      final first = tester.getRect(find.byKey(ValueKey('scripts.card.${ids[0]}')));
      final second = tester.getRect(find.byKey(ValueKey('scripts.card.${ids[1]}')));
      final third = tester.getRect(find.byKey(ValueKey('scripts.card.${ids[2]}')));
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.right));
      expect(third.top, greaterThan(first.bottom));
      expect(first.height, greaterThanOrEqualTo(84));
      await finish(tester);
    });

    testWidgets('deleting asks with Kotlin wording first', (tester) async {
      await pump(tester);
      await vm.saveScript(name: 'Mine', command: 'echo hi', notes: 'a note');
      await tester.pumpAndSettle();
      expect(find.text('a note'), findsOneWidget);
      final id = vm.allScripts.single.id;

      await tester.tap(find.byKey(ValueKey('scripts.card.$id.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete script?'), findsOneWidget);
      expect(find.text('Delete quick script "Mine"?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scripts.delete.confirm')));
      await tester.pumpAndSettle();
      expect(vm.allScripts, isEmpty);
      await finish(tester);
    });

    testWidgets('a preset run through Kotlin seeds keeps its preset key', (tester) async {
      await pump(tester);
      await vm.setPresetsEnabled(fleet: false, enabled: true);
      await tester.pumpAndSettle();
      expect(vm.allScripts.every((s) => s.presetKey != null), isTrue);
      expect(vm.allScripts, hasLength(kHomelabPresets.length));
      await finish(tester);
    });
  });

  testWidgets('Save script from Fleet pre-fills the command as a Fleet command', (tester) async {
    await app.start();
    vm = ScriptsViewModel(app);
    // No Scripts screen here to start the view model's script stream.
    await vm.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showScriptEditorDialog(
                context,
                vm,
                title: 'Save script',
                initialCommand: 'df -h',
                initialCategory: 'Fleet',
                defaultAvailableForQuick: false,
                defaultAvailableForFleet: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Save script'), findsOneWidget);
    expect(find.text('df -h'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('scripts.editor.name')), 'Disk');
    await tester.pumpAndSettle();
    await tapInDialog(tester, find.byKey(const ValueKey('scripts.editor.save')));

    final saved = vm.allScripts.single;
    expect(saved.command, 'df -h');
    expect(saved.category, 'Fleet');
    expect(saved.availableForFleet, isTrue);
    expect(saved.availableForQuick, isFalse);
    await finish(tester);
  });

  testWidgets('a 200% landscape window scrolls instead of overflowing', (tester) async {
    // The API 35 route sweep at 420 dpi: landscape at 200% leaves roughly this much body.
    tester.view.physicalSize = const Size(800, 230);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
