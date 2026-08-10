import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/domain/session_age.dart';

void main() {
  PersistentSession row({required int backgroundedAt}) => PersistentSession(
    tmuxName: 'omniterm-1',
    serverId: 1,
    serverName: 'nas',
    createdAt: 0,
    backgroundedAt: backgroundedAt,
  );

  final now = DateTime(2026, 8, 5, 12);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  test('a session nobody has closed does not claim an age', () {
    // backgroundedAt is 0 until a tab is closed. Rendering that as an elapsed time would date every
    // open session to 1970; the honest phrase is that nobody knows.
    expect(
      describeSessionAge(row(backgroundedAt: 0), now: now),
      contains('still open'),
    );
  });

  test('the phrasing scales with how long it has been sitting there', () {
    expect(
      describeSessionAge(
        row(backgroundedAt: ago(const Duration(seconds: 20))),
        now: now,
      ),
      'left running just now',
    );
    expect(
      describeSessionAge(
        row(backgroundedAt: ago(const Duration(minutes: 4))),
        now: now,
      ),
      'left running 4m ago',
    );
    expect(
      describeSessionAge(
        row(backgroundedAt: ago(const Duration(hours: 5))),
        now: now,
      ),
      'left running 5h ago',
    );
    expect(
      describeSessionAge(
        row(backgroundedAt: ago(const Duration(days: 9))),
        now: now,
      ),
      'left running 9d ago',
    );
  });

  test('a clock that moved backwards produces no number at all', () {
    // A negative age is a fact about the device's clock, not about the session.
    expect(
      describeSessionAge(
        row(
          backgroundedAt: now
              .add(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        ),
        now: now,
      ),
      'left running',
    );
  });

  group('formatSessionAge', () {
    // The age of a live, attached session, ported from `formatSessionAge`
    // (`ui/OmniComponents.kt:504`). Distinct from describeSessionAge above, which is about a
    // session left running with nobody watching. Flutter's ShellSession had no start time at all,
    // so this could not be shown.
    final now = DateTime(2026, 8, 10, 12, 0);
    String age(Duration ago) => formatSessionAge(now.subtract(ago), now: now);

    test(
      'a session opened this second has not been running for zero minutes',
      () {
        expect(age(const Duration(seconds: 5)), 'just now');
        expect(age(Duration.zero), 'just now');
      },
    );

    test('minutes, then hours, then days', () {
      expect(age(const Duration(minutes: 7)), '7m');
      expect(age(const Duration(hours: 2, minutes: 5)), '2h 05m');
      expect(age(const Duration(days: 3, hours: 4)), '3d 04h');
    });

    test('the second field is zero-padded so the width does not jitter', () {
      // A label that changes width every minute drags the controls beside it around.
      expect(age(const Duration(hours: 1, minutes: 9)), '1h 09m');
      expect(age(const Duration(days: 1, hours: 9)), '1d 09h');
    });

    test('an hour exactly still shows its minutes', () {
      expect(age(const Duration(hours: 1)), '1h 00m');
    });

    test('a session with no recorded start says so rather than guessing', () {
      expect(formatSessionAge(null, now: now), '—');
    });

    test('a start in the future is not rendered as a negative age', () {
      // A clock adjustment during a long-lived session produces exactly this.
      expect(
        formatSessionAge(now.add(const Duration(hours: 1)), now: now),
        '—',
      );
    });
  });
}
