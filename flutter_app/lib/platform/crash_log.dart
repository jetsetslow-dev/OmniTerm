import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class CrashEntry {
  const CrashEntry({required this.timeMs, required this.report, this.startup = false});

  final int timeMs;
  final String report;

  /// True when this was thrown while the app was starting, rather than during use.
  ///
  /// Only a startup crash justifies refusing to launch on the next run: one that happened while the
  /// user was working is recorded and reported, but the app plainly *does* start, so blocking it
  /// would strand them over something they had already carried on past.
  final bool startup;

  String get headline => crashHeadline(report);

  Map<String, Object> toJson() => {'t': timeMs, 'r': report, if (startup) 's': true};
}

String crashHeadline(String report) {
  for (final raw in const LineSplitter().convert(report)) {
    final line = raw.trim();
    if (line.isEmpty ||
        line.startsWith('at ') ||
        line.startsWith('#') ||
        line.startsWith('App version') ||
        line.startsWith('Device:') ||
        line.startsWith('Platform:') ||
        line.startsWith('Thread:')) {
      continue;
    }
    return line.length <= 200 ? line : line.substring(0, 200);
  }
  return 'Crash';
}

/// Removes credentials and common machine-identifying values before a crash can be persisted,
/// copied, backed up, or shared.
String redactCrashReport(String report) {
  var safe = report;
  safe = safe.replaceAll(
    RegExp(
      r'-----BEGIN [^-]*(?:PRIVATE KEY|OPENSSH KEY)-----[\s\S]*?-----END [^-]*(?:PRIVATE KEY|OPENSSH KEY)-----',
      caseSensitive: false,
    ),
    '<redacted-private-key>',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'(\b(?:authorization|proxy-authorization)\s*[:=]\s*)(?:bearer|basic)?\s*\S+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'(\b(?:password|passwd|passphrase|secret|token|api[_-]?key|private[_-]?key)\b\s*[:=]\s*)([^\s,;]+)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );
  safe = safe.replaceAllMapped(
    RegExp(r'([a-z][a-z0-9+.-]*://)[^/@\s:]+(?::[^/@\s]*)?@', caseSensitive: false),
    (match) => '${match.group(1)}<redacted>@',
  );
  safe = safe.replaceAll(
    RegExp(r'(?<![A-Za-z0-9_])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9_])'),
    '<redacted-ip>',
  );
  safe = safe.replaceAll(RegExp(r'/(?:home|Users)/[^/\s]+'), '/home/<redacted>');
  safe = safe.replaceAll(RegExp(r'/data/(?:user/\d+|data)/[^/\s]+'), '/data/user/<redacted>');
  return safe;
}

/// Small, private on-device crash history matching the Kotlin app's retention and sanitisation.
class CrashLog extends ChangeNotifier {
  CrashLog() : _preferences = null;

  @visibleForTesting
  CrashLog.withPreferences(this._preferences);

  static final CrashLog instance = CrashLog();
  static const _key = 'flutter_crash_history_entries';
  static const maxEntries = 20;
  static const ttl = Duration(days: 30);

  SharedPreferencesAsync? _preferences;
  List<CrashEntry> _entries = const [];
  String _environment = 'App version: unknown';
  bool _initialized = false;

  List<CrashEntry> get entries => List.unmodifiable(_entries);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _environment = 'App version: ${info.version} (${info.buildNumber})';
    } catch (_) {
      // Host tests have no package-info channel; the report remains usable without it.
    }
    _entries = await _readFresh();
    notifyListeners();
  }

  Future<void> record(
    Object error,
    StackTrace stack, {
    String thread = 'Dart',
    bool startup = false,
  }) async {
    final report = redactCrashReport('$_environment\nThread: $thread\n$error\n$stack');
    final current = await _readFresh();
    _entries = [
      CrashEntry(timeMs: DateTime.now().millisecondsSinceEpoch, report: report, startup: startup),
      ...current,
    ].take(maxEntries).toList(growable: false);
    await _write(_entries);
    notifyListeners();
  }

  Future<void> clear() async {
    _entries = const [];
    await _store()?.remove(_key);
    notifyListeners();
  }

  /// Merges crash diagnostics restored from an explicitly selected encrypted backup.
  Future<int> merge(Iterable<CrashEntry> incoming) async {
    final before = await _readFresh();
    final now = DateTime.now().millisecondsSinceEpoch;
    final seen = <String>{};
    final merged = <CrashEntry>[];
    var imported = 0;
    for (final entry in [...incoming, ...before]..sort((a, b) => b.timeMs.compareTo(a.timeMs))) {
      final safe = CrashEntry(timeMs: entry.timeMs, report: redactCrashReport(entry.report));
      if (safe.timeMs <= 0 || safe.report.isEmpty || now - safe.timeMs >= ttl.inMilliseconds) {
        continue;
      }
      final identity = '${safe.timeMs}\u0000${safe.report}';
      if (!seen.add(identity)) continue;
      merged.add(safe);
      if (!before.any((old) => old.timeMs == safe.timeMs && old.report == safe.report)) {
        imported++;
      }
      if (merged.length == maxEntries) break;
    }
    _entries = merged;
    await _write(_entries);
    notifyListeners();
    return imported;
  }

  Future<List<CrashEntry>> _readFresh() async {
    final store = _store();
    if (store == null) return const [];
    final raw = await store.getString(_key);
    if (raw == null) return const [];
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final decoded = jsonDecode(raw) as List<Object?>;
      final fresh = <CrashEntry>[];
      for (final value in decoded.whereType<Map<String, Object?>>()) {
        final time = (value['t'] as num?)?.toInt() ?? 0;
        final report = value['r'] as String? ?? '';
        if (time > 0 && report.isNotEmpty && now - time < ttl.inMilliseconds) {
          fresh.add(
            CrashEntry(
              timeMs: time,
              report: redactCrashReport(report),
              startup: value['s'] == true,
            ),
          );
        }
      }
      fresh.sort((a, b) => b.timeMs.compareTo(a.timeMs));
      final result = fresh.take(maxEntries).toList(growable: false);
      if (result.length != decoded.length) await _write(result);
      return result;
    } catch (_) {
      await store.remove(_key);
      return const [];
    }
  }

  SharedPreferencesAsync? _store() {
    try {
      return _preferences ??= SharedPreferencesAsync();
    } on StateError {
      // Plain Dart/widget tests do not install a platform implementation.
      return null;
    }
  }

  Future<void> _write(List<CrashEntry> entries) async {
    await _store()?.setString(_key, jsonEncode(entries.map((entry) => entry.toJson()).toList()));
  }
}

/// Installs both framework and root-isolate handlers without replacing Flutter's normal error
/// presentation. The history write is best-effort because the platform may terminate immediately.
Future<void> installCrashHistory() async {
  final log = CrashLog.instance;
  await log.initialize();
  final previousFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    previousFlutterHandler?.call(details);
    unawaited(
      log.record(
        details.exception,
        details.stack ?? StackTrace.current,
        thread: 'Flutter framework',
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(log.record(error, stack, thread: 'Dart root isolate'));
    return false;
  };
}
