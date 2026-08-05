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
}
