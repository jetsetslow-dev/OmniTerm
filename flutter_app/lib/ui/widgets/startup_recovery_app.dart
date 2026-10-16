import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/crash_log.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Replaces Flutter's blank release-mode error surface when the app throws while building.
///
/// This is deliberately a standalone function so [main] can install it as [ErrorWidget.builder]
/// before constructing any provider, database-backed view model, or theme state. Samsung and other
/// production devices must get an actionable report even when the failing value exists only in an
/// upgraded installation and could not be reproduced by a fresh-install smoke test.
Widget startupRecoveryForError(FlutterErrorDetails details) {
  final stack = details.stack ?? StackTrace.current;
  final report = redactCrashReport('${details.exceptionAsString()}\n$stack');
  return StartupRecoveryApp(report: report);
}

/// Shown instead of the app when the last launch crashed while starting.
///
/// Ported from `showCrashReport` (`MainActivity.kt:342`). Its own `MaterialApp`, deliberately: this
/// runs when the real app could not be built, so it must not depend on anything the real app sets
/// up — no providers, no database, no theme controller.
class StartupRecoveryApp extends StatelessWidget {
  const StartupRecoveryApp({super.key, required this.report});

  final String report;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        key: const ValueKey('startup.recovery'),
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'OmniTerm could not start',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 8),
                const Text(
                  // Says what the button does before it is pressed. "Clear" next to a crash report
                  // could as easily mean wiping the app's data, which is the thing the user is
                  // most afraid of at this moment and the thing this avoids.
                  'A crash report was saved on this device. Clearing it lets the app try to start '
                  'again — your hosts, keys and settings are not touched.',
                  style: TextStyle(fontSize: 13, color: OmniColors.textSecondary),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      report,
                      style: const TextStyle(
                        fontFamily: OmniFonts.mono,
                        fontSize: 11,
                        color: OmniColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('startup.recovery.copy'),
                        onPressed: () => Clipboard.setData(ClipboardData(text: report)),
                        child: const Text('Copy report'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('startup.recovery.clear'),
                        onPressed: () async {
                          await CrashLog.instance.clear();
                          // Restarting the process is not something a Flutter app can do to itself,
                          // so it says what it needs rather than pretending it has acted.
                          SystemNavigator.pop();
                        },
                        child: const Text('Clear and close'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
