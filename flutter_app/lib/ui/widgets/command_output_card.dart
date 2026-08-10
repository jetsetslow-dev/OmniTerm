import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'omni_components.dart';

/// Output from a command the app ran on a host.
///
/// The inline equivalent of `ActionStreamDialog` in `ui/AppUi.kt:263`, which Kotlin shows for all
/// fifteen of its streaming actions — reboot, service start/stop/restart/enable/disable, and every
/// Docker container/image/volume/network operation.
///
/// Shared rather than reimplemented per screen, because the requirements are the same wherever
/// remote output lands and they are easy to get half right:
///
/// - **Monospace.** `systemctl status` and `docker` output is column-aligned; a proportional font
///   turns it into noise.
/// - **Selectable and copyable.** This is the text an operator pastes into a search or a bug report.
///   It is the whole reason for keeping it on screen rather than reporting "done".
/// - **Bounded and scrollable.** A failed `apt-get` can run to hundreds of lines, and an unbounded
///   card pushes the list it belongs to off the screen.
class CommandOutputCard extends StatelessWidget {
  const CommandOutputCard({
    super.key,
    required this.keyPrefix,
    required this.output,
    required this.onDismiss,
    this.title = '',
    this.running = false,
    this.maxHeight = 140,
  });

  /// Prefix for this card's widget keys, so each screen keeps its own stable identifiers.
  final String keyPrefix;

  final String output;
  final VoidCallback onDismiss;

  /// What produced this output. Falls back to a generic label rather than an empty header.
  final String title;

  /// Shows a spinner beside the title while the command is still producing output.
  final bool running;

  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return OmniCard(
      key: ValueKey(keyPrefix),
      leftAccent: OmniColors.cyan,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title.isEmpty ? 'Action output' : title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (running)
                      const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    IconButton(
                      key: ValueKey('$keyPrefix.copy'),
                      tooltip: 'Copy output',
                      icon: const Icon(Icons.content_copy, size: 15),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: output));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Output copied')),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: SingleChildScrollView(
                    child: SelectionArea(
                      child: Text(
                        output,
                        key: ValueKey('$keyPrefix.text'),
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: OmniFonts.mono,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('$keyPrefix.dismiss'),
            icon: const Icon(Icons.close, size: 16),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
