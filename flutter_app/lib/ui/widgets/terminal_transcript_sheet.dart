import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/terminal_transcript.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/shell_session.dart';

/// The scrollback as selectable text.
///
/// **The terminal surface paints a grid**, so there is nothing on it to select — which left the one
/// thing people do with terminal output, copy it, impossible. The Kotlin answers this the same way
/// (its PR #69): a long press opens the transcript in the platform's own selectable text control,
/// rather than trying to make a canvas behave like a document.
///
/// Everything the session has is shown, not just the visible grid: the reason to reach for this is
/// usually an error that has already scrolled past.
Future<void> openTerminalTranscript(BuildContext context, ShellSession session) {
  final text = transcriptText(session.emulator.snapshot().rows);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _TranscriptSheet(text: text),
  );
}

class _TranscriptSheet extends StatelessWidget {
  const _TranscriptSheet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Transcript', style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        // Saying the count, because "all of it" is otherwise a guess — and if the
                        // scrollback limit has trimmed the start, this is the number that shows it.
                        text.isEmpty
                            ? 'Nothing has been printed yet.'
                            : '${'\n'.allMatches(text).length + 1} lines',
                        key: const ValueKey('transcript.summary'),
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('transcript.copyAll'),
                  tooltip: 'Copy everything',
                  icon: const Icon(Icons.copy_all, size: 20, color: OmniColors.cyan),
                  onPressed: text.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(const SnackBar(content: Text('Transcript copied')));
                        },
                ),
                IconButton(
                  key: const ValueKey('transcript.close'),
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Container(
                width: double.infinity,
                color: OmniColors.bg0,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    text,
                    key: const ValueKey('transcript.text'),
                    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
