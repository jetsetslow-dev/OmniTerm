/// The in-app review nudge, ported from `noteSuccessfulSshSession` and `onReviewPromptLaunched` in
/// `ui/AppViewModel.kt:1797`.
///
/// **The store call itself is injected and nullable (Convention 4).** Kotlin reaches the Play
/// In-App Review API through `flavorRequestInAppReview`, which is a no-op in its open-source flavor.
/// Wiring an equivalent package in here would be a dependency change, and this repository treats
/// those as a security boundary — new checksums across every resolved graph and both release SBOMs
/// (the repository's strict dependency-verification gate). So the *policy* lives here, fully tested,
/// and the build that has a store SDK supplies the launcher. A build without one simply never
/// prompts, rather than pretending to.
library;

import 'dart:async';

import '../data/app_repository.dart';

/// Asks the platform to show its review sheet. Returns when the request has been handed over —
/// whether a sheet actually appeared is the store's decision, never the app's.
typedef ReviewLauncher = Future<void> Function();

/// How many successful SSH sessions before the nudge is considered, matching Kotlin's `count >= 3`.
///
/// Deliberately not 1. The prompt is meant to arrive after the app has demonstrably worked for
/// someone, not while they are still finding out whether it does.
const reviewPromptAfterSuccesses = 3;

/// Decides whether the review sheet is due.
///
/// Pure so the policy can be tested without a store, a database, or a device. Kotlin's rule exactly:
/// at least [reviewPromptAfterSuccesses] successful sessions, and never more than once ever.
bool reviewPromptIsDue({
  required int successCount,
  required bool alreadyShown,
  required bool canPrompt,
}) => canPrompt && !alreadyShown && successCount >= reviewPromptAfterSuccesses;

/// Counts successful connections and asks for a review once, at the right moment.
class ReviewPromptController {
  ReviewPromptController(this._repository, {this.launcher});

  final AppRepository _repository;

  /// Null in the open-source build, in tests, and anywhere without a store SDK. The nudge is then
  /// simply absent — which is the honest behaviour, not a silent failure.
  final ReviewLauncher? launcher;

  int _successCount = 0;
  bool _alreadyShown = false;
  bool _loaded = false;

  /// Successful SSH sessions recorded so far.
  int get successCount => _successCount;

  /// True once the nudge has been used up. It is one-shot for the life of the install.
  bool get alreadyShown => _alreadyShown;

  bool get canPrompt => launcher != null;

  /// Reads the stored counters. Safe to call more than once.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    _successCount =
        int.tryParse((await _repository.getSetting('ssh_success_count'))?.trim() ?? '') ?? 0;
    _alreadyShown = (await _repository.getSetting('review_prompt_shown'))?.trim() == 'true';
  }

  /// Records a successful SSH session and prompts if this was the one that earned it.
  ///
  /// The count is persisted on **every** success, not only when it crosses the threshold: a user who
  /// connects twice, closes the app, and connects again has connected three times, and Kotlin counts
  /// it that way too.
  Future<void> noteSuccessfulSession() async {
    await load();
    _successCount++;
    await _repository.insertSetting('ssh_success_count', '$_successCount');

    if (!reviewPromptIsDue(
      successCount: _successCount,
      alreadyShown: _alreadyShown,
      canPrompt: canPrompt,
    )) {
      return;
    }

    // Marked as shown *before* the launcher runs, and never retried. Kotlin does the same and says
    // why: the store decides whether a sheet actually appears, so treating "we asked" as "it is used
    // up" is the only way to guarantee the user is never asked twice.
    _alreadyShown = true;
    await _repository.insertSetting('review_prompt_shown', 'true');
    try {
      await launcher!();
    } catch (_) {
      // A store that refuses is not an app error, and it must not surface as one. The nudge is
      // spent either way — retrying is exactly what this flag exists to prevent.
    }
  }
}
