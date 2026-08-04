import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/terminal_emulator.dart';
import 'package:omniterm/ui/view_model/shell_session.dart';

import 'support/fake_terminal_session.dart';

void main() {
  late FakeTerminalSession channel;
  late ShellSession session;

  ShellSession build({int rows = 24, int scrollbackLimit = 2000}) {
    channel = FakeTerminalSession();
    return session = ShellSession(
      id: 's1',
      serverId: 7,
      serverName: 'nas',
      channel: channel,
      emulator: TerminalEmulator(cols: 80, rows: rows, scrollbackLimit: scrollbackLimit),
    )..setViewportRows(rows);
  }

  tearDown(() async {
    session.dispose();
    await channel.dispose();
  });

  /// Let the stream deliver and the publish timer fire.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

  group('output', () {
    test('reaches the emulator and is published', () async {
      build();
      channel.emit('hello\r\n');
      await settle();

      expect(session.snapshot.rows.first.text.trimRight(), 'hello');
    });

    test('a burst is coalesced into far fewer repaints than chunks', () async {
      // `yes` delivers hundreds of chunks a second. Painting per chunk pegs the UI thread on frames
      // nobody can perceive; the emulator still consumes every byte either way.
      build();
      for (var i = 0; i < 200; i++) {
        channel.emit('line $i\r\n');
      }
      await settle();

      expect(session.publishCount, lessThan(20), reason: 'coalesced');
      expect(session.emulator.rowCount(), greaterThan(100), reason: 'nothing was dropped');
    });
  });

  group('viewport', () {
    test('follows the tail by default', () async {
      build(rows: 5);
      for (var i = 0; i < 40; i++) {
        channel.emit('line $i\r\n');
      }
      await settle();

      expect(session.followTail, isTrue);
      expect(session.snapshot.rows.last.text.trim(), isEmpty, reason: 'cursor line');
      expect(session.viewportFirstRow, session.emulator.rowCount() - 5);
    });

    test('scrolling up unpins, and reaching the bottom re-pins', () async {
      build(rows: 5);
      for (var i = 0; i < 40; i++) {
        channel.emit('line $i\r\n');
      }
      await settle();

      session.scrollBy(-10);
      expect(session.followTail, isFalse);
      expect(session.canScrollBack, isTrue);

      session.scrollBy(1000);
      expect(session.followTail, isTrue, reason: 'a flick to the bottom resumes live output');
    });

    test('new output does not drag a scrolled-up viewport', () async {
      build(rows: 5);
      for (var i = 0; i < 40; i++) {
        channel.emit('line $i\r\n');
      }
      await settle();
      session.scrollBy(-20);
      final reading = session.snapshot.rows.first.text;

      channel.emit('later\r\n');
      await settle();

      expect(
        session.snapshot.rows.first.text,
        reading,
        reason: 'the line being read stays put while output arrives below',
      );
    });

    test('trimming the scrollback does not slide the content being read', () async {
      // The reason the anchor is absolute rather than buffer-relative: once the limit is reached,
      // every new line drops one off the head, and a buffer-relative anchor would scroll the text
      // out from under the user at exactly the rate the remote is talking.
      build(rows: 5, scrollbackLimit: 30);
      for (var i = 0; i < 40; i++) {
        channel.emit('line $i\r\n');
      }
      await settle();

      session.scrollBy(-10);
      final reading = session.snapshot.rows.first.text;
      expect(reading.trim(), isNotEmpty);

      for (var i = 0; i < 10; i++) {
        channel.emit('more $i\r\n');
      }
      await settle();

      expect(
        session.emulator.trimmedRowCount,
        greaterThan(0),
        reason: 'the head really was trimmed',
      );
      expect(session.snapshot.rows.first.text, reading);
    });

    test('typing jumps back to the tail', () async {
      build(rows: 5);
      for (var i = 0; i < 40; i++) {
        channel.emit('line $i\r\n');
      }
      await settle();
      session.scrollBy(-15);

      session.write(Uint8List.fromList('x'.codeUnits));

      expect(session.followTail, isTrue, reason: 'keystrokes landing off-screen is disorienting');
    });
  });

  group('resize', () {
    test('tells the remote the new grid', () async {
      build();
      await session.resize(100, 30);

      expect(channel.resizes, [(100, 30)]);
      expect(session.cols, 100);
      expect(session.rows, 30);
    });

    test('a repeated size is not re-sent', () async {
      build();
      await session.resize(100, 30);
      await session.resize(100, 30);

      expect(channel.resizes, hasLength(1));
    });

    test('a burst collapses to the newest size, not a queue of every intermediate one', () async {
      // Rotating the device or opening the keyboard emits a run of sizes. Replaying all of them
      // makes the remote reflow visibly for geometry nobody ever saw.
      build();
      channel.gateResize = Completer<void>();
      final first = session.resize(100, 30);
      await Future<void>.value();

      unawaited(session.resize(90, 28));
      unawaited(session.resize(80, 26));
      unawaited(session.resize(70, 24));

      channel.gateResize!.complete();
      channel.gateResize = null;
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(channel.resizes, [(100, 30), (70, 24)]);
    });

    test('a failing resize does not stop later ones', () async {
      build();
      final failing = _ThrowingResize();
      final s = ShellSession(
        id: 'x',
        serverId: 1,
        serverName: 'h',
        channel: failing,
        emulator: TerminalEmulator(cols: 80, rows: 24),
      );
      await s.resize(100, 30);
      await s.resize(110, 40);

      expect(s.cols, 110, reason: 'the local grid is correct regardless');
      expect(failing.attempts, 2, reason: 'the consumer survived the failure');
      s.dispose();
      await failing.dispose();
    });
  });

  group('endings', () {
    test('a remote exit is reported as an exit, with its status', () async {
      build();
      await channel.endByRemoteExit(status: 3);
      await settle();

      expect(session.endReason, ShellSessionEnd.remoteExited);
      expect(session.exitStatus, 3);
      expect(session.isOpen, isFalse);
    });

    test('a dropped connection is not reported as an exit', () async {
      // The remote may well still be running. Telling the user their shell ended is a lie they act
      // on — and it is the difference between reconnecting and starting over.
      build();
      await channel.dropConnection();
      await settle();

      expect(session.endReason, ShellSessionEnd.disconnected);
    });

    test('the scrollback survives the ending', () async {
      build(rows: 5);
      channel.emit('the last thing it said\r\n');
      await settle();
      await channel.dropConnection();
      await settle();

      expect(
        session.snapshot.rows.any((r) => r.text.contains('the last thing it said')),
        isTrue,
        reason: 'blanking on disconnect destroys the only evidence of why',
      );
    });

    test('writes after the end are dropped rather than thrown', () async {
      build();
      await channel.endByRemoteExit();
      await settle();

      expect(session.write(Uint8List.fromList('x'.codeUnits)), isFalse);
      expect(channel.writes, isEmpty);
    });
  });

  group('read-only', () {
    test('refuses input and says so through the return value', () {
      // A key bar that reports success on a refused session teaches the user to distrust the screen.
      build();
      session.setReadOnly(true);

      expect(session.write(Uint8List.fromList('rm -rf /'.codeUnits)), isFalse);
      expect(channel.writes, isEmpty);
    });

    test('lifting it restores input', () {
      build();
      session.setReadOnly(true);
      session.setReadOnly(false);

      expect(session.write(Uint8List.fromList('ls'.codeUnits)), isTrue);
    });
  });

  test('disposing closes the channel', () async {
    build();
    session.dispose();

    expect(channel.closeCalled, isTrue);
    // Re-disposed by tearDown; the second call must be a no-op rather than a throw.
  });
}

/// A channel whose resize always fails, to prove the consumer keeps running.
class _ThrowingResize extends FakeTerminalSession {
  int attempts = 0;

  @override
  Future<void> resize(int cols, int rows) async {
    attempts++;
    throw StateError('remote refused');
  }
}
