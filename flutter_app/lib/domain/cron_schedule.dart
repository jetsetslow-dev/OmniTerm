/// Reading and writing a remote user's crontab, ported from the cron helpers in `ui/MonitorScreen.kt`
/// and `loadCron`/`saveCron` in `ui/AppViewModel.kt`.
///
/// Everything here is pure text handling, kept away from the transport, because saving a crontab
/// **replaces the whole file**. There is no "edit line 3" in the cron interface: the app reads the
/// user's entire crontab, changes one line, and writes all of it back. That makes the parse the
/// dangerous part — anything it drops is deleted from the user's machine.
library;

/// One line of a crontab.
///
/// [editable] is false for comments, environment assignments (`PATH=...`) and anything that does not
/// look like five schedule fields plus a command. Those lines are shown as they are and **carried
/// through every save untouched**, which is what stops an edit from quietly deleting the `MAILTO`
/// line above it.
class CronLine {
  const CronLine({
    required this.index,
    required this.raw,
    required this.expression,
    required this.command,
    required this.label,
    required this.editable,
  });

  final int index;
  final String raw;

  /// The five schedule fields, or the `@daily`-style shorthand. Empty when not editable.
  final String expression;

  /// The command, without the app's own trailing label comment. Empty when not editable.
  final String command;

  /// The name typed in the dialog, recovered from the `# OmniTerm:` marker. Empty when there is
  /// none — an entry someone wrote by hand is a normal entry, not a broken one.
  final String label;

  final bool editable;
}

/// The `@`-shorthands cron understands, and what each means in words.
const cronShorthands = <String, String>{
  '@reboot': 'At every boot',
  '@yearly': 'Once a year, 1 January at 00:00',
  '@annually': 'Once a year, 1 January at 00:00',
  '@monthly': 'Monthly on day 1 at 00:00',
  '@weekly': 'Every Sunday at 00:00',
  '@daily': 'Every day at 00:00',
  '@midnight': 'Every day at 00:00',
  '@hourly': 'Every hour',
};

const _labelMarker = '# OmniTerm:';

/// Splits a crontab into lines.
///
/// Blank lines are dropped; everything else survives, editable or not.
List<CronLine> parseCrontab(String text) {
  final out = <CronLine>[];
  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final trimmed = lines[index].trim();
    if (trimmed.isEmpty) continue;

    // A shorthand is two fields: `@daily /usr/bin/backup`. Editable, because the dialog can show
    // and rewrite it — but its schedule is not five parts, so it is kept whole.
    final isComment = trimmed.startsWith('#');
    final shorthand = !isComment && trimmed.startsWith('@');
    final parts = trimmed.split(RegExp(r'\s+'));

    if (shorthand && parts.length >= 2 && cronShorthands.containsKey(parts.first)) {
      final rest = trimmed.substring(parts.first.length).trim();
      out.add(
        CronLine(
          index: index,
          raw: trimmed,
          expression: parts.first,
          command: _commandOf(rest),
          label: _labelOf(rest),
          editable: true,
        ),
      );
      continue;
    }

    // Five schedule fields then the command. An `=` in the first field means an environment
    // assignment, which looks nothing like a schedule and must not be edited as one.
    final editable = parts.length >= 6 && !isComment && !parts.first.contains('=');
    if (!editable) {
      out.add(
        CronLine(
          index: index,
          raw: trimmed,
          expression: '',
          command: '',
          label: '',
          editable: false,
        ),
      );
      continue;
    }

    final rest = _remainderAfter(trimmed, 5);
    out.add(
      CronLine(
        index: index,
        raw: trimmed,
        expression: parts.take(5).join(' '),
        command: _commandOf(rest),
        label: _labelOf(rest),
        editable: true,
      ),
    );
  }
  return out;
}

/// Everything after the first [count] whitespace-separated fields of [line], **verbatim**.
///
/// Splitting the whole line and rejoining with single spaces looks equivalent and is not: it
/// rewrites the command's own spacing. `--name "My  Backup"` becomes `--name "My Backup"`, which is
/// a different argument — and because the schedule dialog seeds its command field from this value,
/// editing only the *schedule* would silently change what the job does.
///
/// Kotlin gets this free from `split(Regex("\\s+"), limit = 6)` (`ui/MonitorScreen.kt:422`), where
/// the sixth element is the untouched remainder.
String _remainderAfter(String line, int count) {
  var index = 0;
  for (var field = 0; field < count; field++) {
    while (index < line.length && !_isSpace(line.codeUnitAt(index))) {
      index++;
    }
    while (index < line.length && _isSpace(line.codeUnitAt(index))) {
      index++;
    }
  }
  return line.substring(index);
}

bool _isSpace(int code) => code == 0x20 || code == 0x09;

String _commandOf(String rest) {
  final marker = rest.indexOf(_labelMarker);
  return (marker < 0 ? rest : rest.substring(0, marker)).trim();
}

String _labelOf(String rest) {
  final marker = rest.indexOf(_labelMarker);
  return marker < 0 ? '' : rest.substring(marker + _labelMarker.length).trim();
}

/// Builds one crontab line from the dialog's fields.
///
/// The label rides in a trailing comment so it survives a round trip through the remote crontab —
/// cron has nowhere else to put it, and an app-side name would be lost the moment anyone edited the
/// file by hand.
String cronLineFor({required String expression, required String command, String label = ''}) {
  final base = '${expression.trim()} ${command.trim()}';
  final name = label.trim();
  return name.isEmpty ? base : '$base $_labelMarker $name';
}

/// Renders [lines] back to a crontab body, newline-terminated as cron requires.
///
/// A crontab whose last line has no newline is rejected outright by some cron implementations and
/// silently truncated by others.
String renderCrontab(Iterable<CronLine> lines) {
  final body = lines.map((l) => l.raw).join('\n').trimRight();
  return body.isEmpty ? '' : '$body\n';
}

/// Whether one schedule field is something cron will accept.
///
/// Deliberately permissive about what it does not know (names like `MON`, step syntax on a range):
/// this exists to catch a typed `99` in the minute field before it is written, not to reimplement
/// cron's grammar. §17 — warn, do not block.
bool isCronPartValid(String part, int min, int max) {
  final trimmed = part.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed == '*') return true;

  final cleaned = trimmed.startsWith('*/') ? trimmed.substring(2) : trimmed;
  if (cleaned.isEmpty) return false;

  return cleaned.split(RegExp('[,-]')).every((token) {
    if (token == '*') return true;
    final value = int.tryParse(token);
    return value != null && value >= min && value <= max;
  });
}

/// True when every field of a five-part expression is acceptable.
bool isCronExpressionValid(String expression) {
  final trimmed = expression.trim();
  if (cronShorthands.containsKey(trimmed)) return true;

  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length != 5) return false;
  return isCronPartValid(parts[0], 0, 59) &&
      isCronPartValid(parts[1], 0, 23) &&
      isCronPartValid(parts[2], 1, 31) &&
      isCronPartValid(parts[3], 1, 12) &&
      // 0 and 7 are both Sunday, which is why the upper bound is 7 and not 6.
      isCronPartValid(parts[4], 0, 7);
}

/// The preset expressions the dialog offers.
const cronPresets = <String, String>{
  'hourly': '0 * * * *',
  'daily': '0 2 * * *',
  'weekly': '0 2 * * 0',
  'monthly': '0 2 1 * *',
};

/// Which preset [expression] is, or `custom`.
String cronPresetFor(String? expression) {
  final trimmed = expression?.trim() ?? '';
  for (final entry in cronPresets.entries) {
    if (entry.value == trimmed) return entry.key;
  }
  return 'custom';
}

/// A schedule in words.
///
/// The Kotlin recognises only its own four presets and calls everything else "Custom schedule",
/// which means the most common hand-written schedules — every five minutes, every weekday morning —
/// are described as nothing at all. This reads the common shapes back.
String cronSummary(String expression) {
  final trimmed = expression.trim();
  final shorthand = cronShorthands[trimmed];
  if (shorthand != null) return shorthand;

  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length != 5) return 'Custom schedule';
  final (minute, hour, day, month, weekday) = (parts[0], parts[1], parts[2], parts[3], parts[4]);

  final everyDate = day == '*' && month == '*';
  final at = _timeOfDay(minute, hour);

  final everyDay = everyDate && weekday == '*';
  if (minute.startsWith('*/') && hour == '*' && everyDay) {
    return 'Every ${minute.substring(2)} minutes';
  }
  if (minute == '*' && hour == '*' && everyDay) return 'Every minute';
  if (hour.startsWith('*/') && everyDay && int.tryParse(minute) != null) {
    return 'Every ${hour.substring(2)} hours, at ${minute.padLeft(2, '0')} past';
  }
  if (hour == '*' && everyDay && int.tryParse(minute) != null) {
    // On the hour is "every hour"; anything else needs the offset said out loud, or two different
    // schedules read identically.
    return minute == '0' ? 'Every hour' : 'Every hour at ${minute.padLeft(2, '0')} past';
  }
  if (at == null) return 'Custom schedule';

  if (everyDay) return 'Every day at $at';
  if (everyDate && weekday != '*') return '${_weekdayName(weekday)} at $at';
  if (month == '*' && weekday == '*' && int.tryParse(day) != null) {
    return 'Monthly on day $day at $at';
  }
  return 'Custom schedule';
}

/// `HH:MM`, or null when either field is not a plain number.
String? _timeOfDay(String minute, String hour) {
  final m = int.tryParse(minute);
  final h = int.tryParse(hour);
  if (m == null || h == null) return null;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

const _weekdayNames = {
  '0': 'Every Sunday',
  '7': 'Every Sunday',
  '1': 'Every Monday',
  '2': 'Every Tuesday',
  '3': 'Every Wednesday',
  '4': 'Every Thursday',
  '5': 'Every Friday',
  '6': 'Every Saturday',
  '1-5': 'Every weekday',
  '6,0': 'Every weekend day',
  '0,6': 'Every weekend day',
};

String _weekdayName(String weekday) => _weekdayNames[weekday.trim()] ?? 'On a schedule';
