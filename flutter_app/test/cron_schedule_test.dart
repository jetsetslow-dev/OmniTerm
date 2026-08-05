import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/domain/cron_schedule.dart';

void main() {
  group('parseCrontab', () {
    test('an ordinary entry splits into schedule and command', () {
      final lines = parseCrontab('0 2 * * * /usr/bin/backup --full\n');

      expect(lines.single.expression, '0 2 * * *');
      expect(lines.single.command, '/usr/bin/backup --full');
      expect(lines.single.editable, isTrue);
    });

    test('a command with its own spacing survives intact', () {
      final lines = parseCrontab('*/5 * * * * sh -c "echo hi > /tmp/x" && true');
      expect(lines.single.command, 'sh -c "echo hi > /tmp/x" && true');
    });

    test('the app\'s label is recovered and kept out of the command', () {
      final lines = parseCrontab('0 2 * * * /usr/bin/backup # OmniTerm: Nightly backup');

      expect(lines.single.command, '/usr/bin/backup');
      expect(lines.single.label, 'Nightly backup');
    });

    test('an entry written by hand has no label and is not broken by that', () {
      expect(parseCrontab('0 2 * * * /usr/bin/backup').single.label, '');
    });

    group('lines that must never be edited as schedules', () {
      test('a comment', () {
        final line = parseCrontab('# do not touch this file').single;
        expect(line.editable, isFalse);
        expect(line.raw, '# do not touch this file');
      });

      test('an environment assignment', () {
        // `MAILTO=ops@example.com` has six whitespace-separated fields in some spellings and would
        // otherwise be parsed as a schedule with `MAILTO=ops@example.com` as the minute.
        for (final raw in ['MAILTO=ops@example.com', 'PATH=/usr/local/bin:/usr/bin:/bin']) {
          expect(parseCrontab(raw).single.editable, isFalse, reason: raw);
        }
      });

      test('a line with too few fields', () {
        expect(parseCrontab('0 2 * * *').single.editable, isFalse);
      });
    });

    test('everything in the file is kept, editable or not', () {
      // This is the whole safety property: a save writes back what parse produced, so a line that
      // parse drops is a line deleted from the user's machine.
      const raw =
          'MAILTO=ops@example.com\n'
          '# nightly jobs\n'
          '0 2 * * * /usr/bin/backup\n'
          '\n'
          '@reboot /usr/local/bin/warm-cache\n';
      final lines = parseCrontab(raw);

      expect(lines, hasLength(4), reason: 'the blank line is the only thing dropped');
      expect(renderCrontab(lines), 'MAILTO=ops@example.com\n'
          '# nightly jobs\n'
          '0 2 * * * /usr/bin/backup\n'
          '@reboot /usr/local/bin/warm-cache\n');
    });

    test('a shorthand schedule is understood rather than shown as raw text', () {
      final line = parseCrontab('@daily /usr/bin/backup # OmniTerm: Nightly').single;

      expect(line.editable, isTrue);
      expect(line.expression, '@daily');
      expect(line.command, '/usr/bin/backup');
      expect(line.label, 'Nightly');
    });

    test('an invented shorthand is left alone', () {
      expect(parseCrontab('@fortnightly /usr/bin/backup').single.editable, isFalse);
    });
  });

  group('renderCrontab', () {
    test('the file ends with a newline', () {
      // Some cron implementations reject a crontab whose last line has none; others silently
      // truncate it.
      expect(renderCrontab(parseCrontab('0 2 * * * /bin/true')), endsWith('\n'));
    });

    test('an empty crontab renders as nothing, not as a blank line', () {
      expect(renderCrontab(const []), '');
    });
  });

  group('cronLineFor', () {
    test('a labelled entry carries its name in a trailing comment', () {
      expect(
        cronLineFor(expression: '0 2 * * *', command: '/usr/bin/backup', label: 'Nightly'),
        '0 2 * * * /usr/bin/backup # OmniTerm: Nightly',
      );
    });

    test('no label means no comment', () {
      expect(cronLineFor(expression: '0 2 * * *', command: '/bin/true'), '0 2 * * * /bin/true');
    });

    test('what it writes is what parse reads back', () {
      final line = cronLineFor(expression: '*/5 * * * *', command: 'echo hi', label: 'Ping');
      final parsed = parseCrontab(line).single;

      expect(parsed.expression, '*/5 * * * *');
      expect(parsed.command, 'echo hi');
      expect(parsed.label, 'Ping');
    });
  });

  group('isCronPartValid', () {
    test('the ordinary forms', () {
      expect(isCronPartValid('*', 0, 59), isTrue);
      expect(isCronPartValid('0', 0, 59), isTrue);
      expect(isCronPartValid('59', 0, 59), isTrue);
      expect(isCronPartValid('*/5', 0, 59), isTrue);
      expect(isCronPartValid('1,15,30', 0, 59), isTrue);
      expect(isCronPartValid('1-5', 0, 7), isTrue);
    });

    test('a value outside the field is rejected before it is written', () {
      expect(isCronPartValid('60', 0, 59), isFalse);
      expect(isCronPartValid('24', 0, 23), isFalse);
      expect(isCronPartValid('0', 1, 31), isFalse, reason: 'there is no day 0');
      expect(isCronPartValid('', 0, 59), isFalse);
      expect(isCronPartValid('nonsense', 0, 59), isFalse);
    });

    test('Sunday is both 0 and 7', () {
      expect(isCronPartValid('0', 0, 7), isTrue);
      expect(isCronPartValid('7', 0, 7), isTrue);
      expect(isCronPartValid('8', 0, 7), isFalse);
    });

    test('a whole expression is judged field by field', () {
      expect(isCronExpressionValid('0 2 * * *'), isTrue);
      expect(isCronExpressionValid('@daily'), isTrue);
      expect(isCronExpressionValid('0 99 * * *'), isFalse);
      expect(isCronExpressionValid('0 2 * *'), isFalse, reason: 'four fields is not a schedule');
    });
  });

  group('cronSummary', () {
    test('the four presets read back as their preset', () {
      expect(cronSummary('0 * * * *'), 'Every hour');
      expect(cronSummary('0 2 * * *'), 'Every day at 02:00');
      expect(cronSummary('0 2 * * 0'), 'Every Sunday at 02:00');
      expect(cronSummary('0 2 1 * *'), 'Monthly on day 1 at 02:00');
    });

    test('the common hand-written shapes are described, not called custom', () {
      // The Kotlin recognises only its own four presets, so "every five minutes" — probably the
      // single most common cron line in existence — is summarised as "Custom schedule".
      expect(cronSummary('*/5 * * * *'), 'Every 5 minutes');
      expect(cronSummary('* * * * *'), 'Every minute');
      expect(cronSummary('30 * * * *'), 'Every hour at 30 past');
      expect(cronSummary('0 */6 * * *'), 'Every 6 hours, at 00 past');
      expect(cronSummary('30 7 * * 1-5'), 'Every weekday at 07:30');
      expect(cronSummary('0 9 * * 6'), 'Every Saturday at 09:00');
    });

    test('shorthands say what they do', () {
      expect(cronSummary('@reboot'), 'At every boot');
      expect(cronSummary('@daily'), 'Every day at 00:00');
    });

    test('something genuinely unusual is admitted as unusual', () {
      // Better than a confident wrong sentence about when someone's job will run.
      expect(cronSummary('0 0 1,15 */2 3'), 'Custom schedule');
      expect(cronSummary('gibberish'), 'Custom schedule');
    });

    test('presets map both ways', () {
      for (final entry in cronPresets.entries) {
        expect(cronPresetFor(entry.value), entry.key);
      }
      expect(cronPresetFor('*/5 * * * *'), 'custom');
      expect(cronPresetFor(null), 'custom');
    });
  });

  group('reading the remote crontab', () {
    test('a crontab that was read is returned as-is', () {
      final read = parseCrontabRead('0 2 * * * /bin/true\n$cronExitMarker'
          '0\n');

      expect(read.readable, isTrue);
      expect(read.text, '0 2 * * * /bin/true');
    });

    test('"no crontab for user" is an empty crontab, not a failure', () {
      // Every implementation prints this on stderr and exits non-zero. Treating it as a failure
      // would leave a first-time user unable to add their first entry.
      final read = parseCrontabRead('no crontab for omniterm\n${cronExitMarker}1\n');

      expect(read.readable, isTrue);
      expect(read.text, '');
    });

    test('a refusal is NOT an empty crontab', () {
      // The defect this exists for: the Kotlin sends `crontab -l 2>/dev/null || true`, so this
      // answer arrives as "". The screen then offers Add, and saving writes the whole file — so a
      // crontab the user was not allowed to read is replaced by one line.
      final read = parseCrontabRead(
        'You (omniterm) are not allowed to use this program\n${cronExitMarker}1\n',
      );

      expect(read.readable, isFalse);
      expect(read.error, contains('not allowed'));
    });

    test('a host with no cron at all is reported, not treated as empty', () {
      final read = parseCrontabRead('sh: crontab: not found\n${cronExitMarker}127\n');
      expect(read.readable, isFalse);
      expect(read.error, contains('not found'));
    });

    test('a truncated reply is a failure, because it is not an answer', () {
      expect(parseCrontabRead('').readable, isFalse);
      expect(parseCrontabRead('0 2 * * * /bin/true\n').readable, isFalse);
    });
  });

  group('crontabWriteCommand', () {
    test('the body travels base64-encoded', () {
      // A crontab is full of %, *, quotes and $, every one of which means something to the shell.
      final command = crontabWriteCommand('*/5 * * * * echo "50% done" > /tmp/x\n');

      expect(command, isNot(contains('50%')));
      expect(command, contains('| crontab -'));
    });

    test('all three base64 spellings are tried', () {
      // GNU, BusyBox and BSD/macOS disagree on the flag, and homelabs run all three.
      final command = crontabWriteCommand('0 2 * * * /bin/true');

      expect(command, contains('base64 -d'));
      expect(command, contains('base64 --decode'));
      expect(command, contains('base64 -D'));
    });

    test('the file is newline-terminated whatever it was handed', () {
      // Decoding what the command carries proves it, rather than trusting the string it was built
      // from.
      for (final body in ['0 2 * * * /bin/true', '0 2 * * * /bin/true\n\n\n']) {
        final command = crontabWriteCommand(body);
        final encoded = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(command)!.group(1)!;
        expect(String.fromCharCodes(base64Decode(encoded)), '0 2 * * * /bin/true\n');
      }
    });
  });
}
