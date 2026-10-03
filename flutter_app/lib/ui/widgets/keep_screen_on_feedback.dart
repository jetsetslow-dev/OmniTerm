import 'package:flutter/material.dart';

import '../shell_state.dart';
import 'popup_scroll_behavior.dart';

/// Global feedback also covers changes triggered by saved settings or the battery saver.
class KeepScreenOnFeedback extends StatelessWidget {
  const KeepScreenOnFeedback({super.key, required this.shell});

  final ShellState shell;

  Future<void> _showDetails(BuildContext context, String message) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('keepScreenOn.details'),
      title: const Text('Keep screen on'),
      content: SizedBox(
        width: double.maxFinite,
        child: ScrollConfiguration(
          behavior: const PopupScrollBehavior(),
          child: SingleChildScrollView(
            child: Text(message, key: const ValueKey('keepScreenOn.details.message')),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('keepScreenOn.details.close'),
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: shell,
    builder: (context, _) {
      if (!shell.isSettingKeepScreenOn && shell.keepScreenOnError == null) {
        return const SizedBox.shrink();
      }
      final scheme = Theme.of(context).colorScheme;
      return Material(
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (shell.isSettingKeepScreenOn) ...[
                const LinearProgressIndicator(key: ValueKey('keepScreenOn.progress')),
                const SizedBox(height: 4),
                Text(
                  shell.requestedKeepScreenOn
                      ? 'Enabling Keep screen on…'
                      : 'Disabling Keep screen on…',
                  key: const ValueKey('keepScreenOn.pending'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _showDetails(context, shell.keepScreenOnError!),
                        child: Text(
                          shell.keepScreenOnError!,
                          key: const ValueKey('keepScreenOn.error'),
                          style: TextStyle(color: scheme.error),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('keepScreenOn.details.open'),
                      tooltip: 'Keep screen on error details',
                      onPressed: () => _showDetails(context, shell.keepScreenOnError!),
                      icon: const Icon(Icons.info_outline),
                    ),
                    IconButton(
                      key: const ValueKey('keepScreenOn.retry'),
                      tooltip: 'Retry Keep screen on',
                      onPressed: shell.retryKeepScreenOn,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      key: const ValueKey('keepScreenOn.dismiss'),
                      tooltip: 'Dismiss Keep screen on error',
                      onPressed: shell.dismissKeepScreenOnError,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
            ],
          ),
        ),
      );
    },
  );
}
