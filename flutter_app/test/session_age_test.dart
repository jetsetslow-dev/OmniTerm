import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/domain/session_age.dart';
import 'package:omniterm/l10n/app_localizations_en.dart';

void main() {
  PersistentSession row({required int backgroundedAt}) => PersistentSession(
    tmuxName: 'omniterm-1',
    serverId: 1,
    serverName: 'nas',
    createdAt: 0,
    backgroundedAt: backgroundedAt,
    adopted: false,
  );

  final now = DateTime(2026, 8, 5, 12);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  test('a session nobody has closed does not claim an age', () {
    // backgroundedAt is 0 until a tab is closed. Rendering that as an elapsed time would date every
    // open session to 1970; the honest phrase is that nobody knows.
    expect(describeSessionAge(row(backgroundedAt: 0), now: now), contains('still open'));
  });

  test('the phrasing scales with how long it has been sitting there', () {
    expect(
      describeSessionAge(row(backgroundedAt: ago(const Duration(seconds: 20))), now: now),
      'left running just now',
    );
    expect(
      describeSessionAge(row(backgroundedAt: ago(const Duration(minutes: 4))), now: now),
      'left running 4m ago',
    );
    expect(
      describeSessionAge(row(backgroundedAt: ago(const Duration(hours: 5))), now: now),
      'left running 5h ago',
    );
    expect(
      describeSessionAge(row(backgroundedAt: ago(const Duration(days: 9))), now: now),
      'left running 9d ago',
    );
  });

  test('a clock that moved backwards produces no number at all', () {
    // A negative age is a fact about the device's clock, not about the session.
    expect(
      describeSessionAge(
        row(backgroundedAt: now.add(const Duration(hours: 2)).millisecondsSinceEpoch),
        now: now,
      ),
      'left running',
    );
  });

  group('ageText', () {
    // The age line of a live session, a tmux session and a host's last check-in, ported from
    // `ageText` (`ui/OmniComponents.kt`) with the strings generated from Kotlin's. Distinct from
    // describeSessionAge above, which is about a session left running with nobody watching.
    final l10n = AppLocalizationsEn();
    final now = DateTime(2026, 8, 10, 12, 0);
    String started(Duration ago) => ageText(
      l10n.startedAgo,
      l10n.startedJustNow,
      now.subtract(ago).millisecondsSinceEpoch,
      now: now,
    );

    test('the first minute is "just now", never "just now ago"', () {
      expect(started(const Duration(seconds: 59)), 'Started just now');
      expect(started(Duration.zero), 'Started just now');
      expect(
        ageText(
          l10n.backgroundedAgo,
          l10n.backgroundedJustNow,
          now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch,
          now: now,
        ),
        'backgrounded just now',
      );
      expect(
        ageText(
          l10n.lastSeenAgo,
          l10n.lastSeenJustNow,
          now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch,
          now: now,
        ),
        'Last seen just now',
      );
    });

    test('minutes, then hours, then days', () {
      expect(started(const Duration(minutes: 1)), 'Started 1m ago');
      expect(started(const Duration(minutes: 7)), 'Started 7m ago');
      expect(started(const Duration(hours: 2, minutes: 5)), 'Started 2h 05m ago');
      expect(started(const Duration(days: 3, hours: 4)), 'Started 3d 04h ago');
      expect(
        ageText(
          l10n.backgroundedAgo,
          l10n.backgroundedJustNow,
          now.subtract(const Duration(hours: 3, minutes: 4)).millisecondsSinceEpoch,
          now: now,
        ),
        'backgrounded 3h 04m ago',
      );
    });

    test('the second field is zero-padded so the width does not jitter', () {
      // A label that changes width every minute drags the controls beside it around.
      expect(started(const Duration(hours: 1, minutes: 9)), 'Started 1h 09m ago');
      expect(started(const Duration(days: 1, hours: 9)), 'Started 1d 09h ago');
    });

    test('an hour exactly still shows its minutes', () {
      expect(started(const Duration(hours: 1)), 'Started 1h 00m ago');
    });

    test('no recorded time says so rather than guessing', () {
      expect(ageText(l10n.startedAgo, l10n.startedJustNow, 0, now: now), 'Started — ago');
    });

    test('a time ahead of the clock is just now, not a negative age', () {
      // A clock set back during a long-lived session produces exactly this.
      expect(started(const Duration(hours: -1)), 'Started just now');
    });
  });
}
