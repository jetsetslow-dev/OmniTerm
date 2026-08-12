import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;
import 'package:omniterm/platform/crash_log.dart';

/// Crash history, driven on a device: recorded, listed, copied, cleared.
///
/// **Why this needs a device.** The history is held in `SharedPreferences`, which is a platform
/// channel — on a host it is an in-memory stub, so nothing about writing a report, reading it back
/// after the app rebuilds, or the 30-day/20-entry pruning is exercised for real. The copy button
/// reaches the platform clipboard for the same reason. Both are the parts a user actually depends
/// on when they are trying to send someone a crash.
///
/// The report is planted through [CrashLog] rather than by crashing the app on purpose: a real
/// startup crash puts the app into the recovery screen and refuses to launch, which is its own flow
/// (`startup.recovery`) and cannot be the setup for this one.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A report carrying exactly the kind of thing the redactor exists to remove, so "the clipboard
  /// got the report" and "the clipboard got the *secret*" cannot be confused for each other.
  const secret = 'hunter2-should-never-be-copied';
  const marker = 'OmniTermDeviceCrashProbe';

  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done, {int maxFrames = 200}) async {
    for (var i = 0; i < maxFrames && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lays the whole of About out at once, so nothing has to be scrolled to.
  ///
  /// About is a `ListView`, which builds only what is on screen — a control further down does not
  /// merely sit off-screen, it does not exist yet, and a finder reports zero widgets rather than an
  /// invisible one. `test/integration_test/app_lock_test.dart` uses a tall surface for the same
  /// reason on the same kind of screen.
  void layOutWholeScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> openCrashHistory(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nav.tools')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('tools.about')));
    await settle(tester);
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('about.crashHistory')).evaluate().isNotEmpty,
    );
  }

  setUp(() async {
    // Left clean on the way in as well as out: a device carries its store between runs, and an
    // entry from a previous failure would make index 0 someone else's crash.
    await CrashLog.instance.initialize();
    await CrashLog.instance.clear();
  });

  tearDown(() async => CrashLog.instance.clear());

  testWidgets('a recorded crash survives to the screen, and is copied redacted', (tester) async {
    await CrashLog.instance.record(
      StateError('$marker password: $secret'),
      StackTrace.fromString('#0      probe (package:omniterm/probe.dart:1:1)'),
    );

    layOutWholeScreen(tester);
    app.main();
    await settle(tester, frames: 30);
    await openCrashHistory(tester);

    // Read back through the UI, which means it went through SharedPreferences on the device and
    // came out again — the half a host test replaces with a stub.
    expect(find.byKey(const ValueKey('about.crashHistory.0')), findsOneWidget);
    expect(find.textContaining(marker), findsWidgets, reason: 'the headline names the crash');

    await tester.tap(find.byKey(const ValueKey('about.crashHistory.0')));
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('about.crashHistory.0.copy')));
    await settle(tester);

    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, isNotNull, reason: 'Copy must put the report on the real clipboard');
    expect(clip!.text, contains(marker));
    // The redaction happens once, when the crash is recorded, so every export path is safe by
    // construction rather than each remembering to do it — the same place Kotlin does it
    // (`data/CrashLog.kt:46`). This asserts the property at the end of the path a user takes.
    expect(
      clip.text,
      isNot(contains(secret)),
      reason: 'a password in a crash report must not reach the clipboard',
    );
    expect(clip.text, contains('<redacted>'));
  });

  testWidgets('clearing empties the history and says so', (tester) async {
    await CrashLog.instance.record(
      StateError('$marker second run'),
      StackTrace.fromString('#0      probe (package:omniterm/probe.dart:1:1)'),
    );

    layOutWholeScreen(tester);
    app.main();
    await settle(tester, frames: 30);
    await openCrashHistory(tester);
    expect(find.byKey(const ValueKey('about.crashHistory.0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('about.crashHistory.clear')));
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('about.crashHistory.0')).evaluate().isEmpty,
    );

    expect(find.byKey(const ValueKey('about.crashHistory.0')), findsNothing);
    expect(find.textContaining('No crashes recorded'), findsOneWidget);
  });
}
