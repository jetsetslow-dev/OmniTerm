import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/startup_recovery.dart';

/// The startup crash gate, ported from `MainActivity.onCreate` (`MainActivity.kt:55`).
///
/// Flutter recorded crashes and listed them under About, but nothing guarded *startup* — an
/// exception while opening the database killed the app before any UI existed, and every relaunch
/// did the same. Clearing app data was the only escape, which throws away every saved host.
void main() {
  const now = 1000000000;
  final ttl = startupCrashTtl.inMilliseconds;

  StartupCrashVerdict verdict({String? report = 'boom', int? at}) =>
      classifyStartupCrash(report: report, recordedAtMs: at ?? now, nowMs: now);

  test('no recorded crash starts normally', () {
    expect(verdict(report: null), StartupCrashVerdict.none);
    expect(verdict(report: ''), StartupCrashVerdict.none);
    expect(verdict(report: '   '), StartupCrashVerdict.none);
  });

  test('a crash from this launch offers recovery', () {
    expect(verdict(at: now - 1000), StartupCrashVerdict.offerRecovery);
  });

  test('a crash just inside the window still offers recovery', () {
    expect(verdict(at: now - ttl + 1), StartupCrashVerdict.offerRecovery);
  });

  test('a crash older than the window is stale', () {
    // A report from months ago is not evidence about this launch, and a recovery screen that will
    // not go away is its own kind of broken app.
    expect(verdict(at: now - ttl - 1), StartupCrashVerdict.stale);
  });

  test('exactly at the window is stale, not recent', () {
    expect(verdict(at: now - ttl), StartupCrashVerdict.stale);
  });

  test('a crash with no timestamp is stale rather than permanent', () {
    // A report written before the timestamp existed would otherwise offer recovery forever.
    expect(verdict(at: 0), StartupCrashVerdict.stale);
  });

  test('a timestamp in the future offers recovery rather than being discarded', () {
    // A device whose clock moved backwards makes a real crash look like it has not happened yet.
    // Erring toward offering a way out is the safe direction when the alternative is relaunching
    // into the crash.
    expect(verdict(at: now + 60000), StartupCrashVerdict.offerRecovery);
  });
}
