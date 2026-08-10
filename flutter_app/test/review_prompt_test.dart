import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/review_prompt.dart';
import 'package:omniterm/platform/secret_store.dart';

import 'support/fake_secure_storage.dart';

/// The in-app review nudge, ported from `noteSuccessfulSshSession` in `ui/AppViewModel.kt:1797`.
///
/// The store call is injected, so everything that decides *whether* to ask is testable without a
/// store, a device, or a new dependency. What is not covered here is the platform sheet itself —
/// this build has no store SDK wired, by design.
void main() {
  late AppDatabase db;
  late AppRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
  });

  tearDown(() => db.close());

  group('reviewPromptIsDue', () {
    test('waits for three successes, as Kotlin does', () {
      for (final count in [0, 1, 2]) {
        expect(
          reviewPromptIsDue(successCount: count, alreadyShown: false, canPrompt: true),
          isFalse,
          reason: 'asking after $count sessions is asking before the app has proven itself',
        );
      }
      expect(
        reviewPromptIsDue(successCount: 3, alreadyShown: false, canPrompt: true),
        isTrue,
      );
    });

    test('never asks twice', () {
      expect(
        reviewPromptIsDue(successCount: 99, alreadyShown: true, canPrompt: true),
        isFalse,
      );
    });

    test('never asks when there is nothing to ask with', () {
      // The open-source build has no store. Counting is harmless; prompting would be a dead end.
      expect(
        reviewPromptIsDue(successCount: 99, alreadyShown: false, canPrompt: false),
        isFalse,
      );
    });
  });

  group('ReviewPromptController', () {
    test('counts every success, and persists the count each time', () async {
      final controller = ReviewPromptController(repo);

      await controller.noteSuccessfulSession();
      await controller.noteSuccessfulSession();

      expect(controller.successCount, 2);
      expect(await repo.getSetting('ssh_success_count'), '2');
    });

    test('the count survives a restart', () async {
      // Two sessions, quit, one more: that is three connections, not one.
      await repo.insertSetting('ssh_success_count', '2');
      var launched = 0;
      final controller = ReviewPromptController(repo, launcher: () async => launched++);

      await controller.noteSuccessfulSession();

      expect(controller.successCount, 3);
      expect(launched, 1);
    });

    test('the third success asks, and nothing after it does', () async {
      var launched = 0;
      final controller = ReviewPromptController(repo, launcher: () async => launched++);

      for (var i = 0; i < 6; i++) {
        await controller.noteSuccessfulSession();
      }

      expect(launched, 1, reason: 'the nudge is one-shot for the life of the install');
      expect(await repo.getSetting('review_prompt_shown'), 'true');
      expect(controller.successCount, 6, reason: 'counting continues regardless');
    });

    test('a prompt already used up is never repeated after a restart', () async {
      await repo.insertSetting('ssh_success_count', '10');
      await repo.insertSetting('review_prompt_shown', 'true');
      var launched = 0;
      final controller = ReviewPromptController(repo, launcher: () async => launched++);

      await controller.noteSuccessfulSession();

      expect(launched, 0);
    });

    test('without a launcher it counts but never prompts', () async {
      final controller = ReviewPromptController(repo);

      for (var i = 0; i < 5; i++) {
        await controller.noteSuccessfulSession();
      }

      expect(controller.successCount, 5);
      expect(
        await repo.getSetting('review_prompt_shown'),
        isNull,
        reason: 'a build that cannot ask must not record that it did',
      );
    });

    test('a store that throws still spends the nudge', () async {
      // Marked shown before the call and never retried: the store decides whether a sheet appears,
      // so "we asked" has to count as used up or the user gets asked again on the next launch.
      final controller = ReviewPromptController(
        repo,
        launcher: () async => throw StateError('no store on this device'),
      );

      await repo.insertSetting('ssh_success_count', '2');
      await controller.noteSuccessfulSession();

      expect(await repo.getSetting('review_prompt_shown'), 'true');
    });
  });
}
