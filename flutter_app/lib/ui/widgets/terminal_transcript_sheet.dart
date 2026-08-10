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
/// **Opens on the visible screen, with the full buffer one tap away.** Kotlin offers exactly these
/// two ranges and makes the visible screen the long-press default (`ui/ShellScreen.kt:2086`, and the
/// chooser at `:2491`). The default matters in both directions: the common reason to reach for this
/// is to copy the error currently on screen, and rendering a two-thousand-row scrollback into
/// selectable text on every long press is the expensive case, not the useful one.
Future<void> openTerminalTranscript(BuildContext context, ShellSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _TranscriptSheet(session: session),
  );
}

/// Which slice of the session's output the transcript is showing.
enum TranscriptRange {
  /// Only the rows currently on screen.
  visibleScreen,

  /// Everything the session still holds, scrollback included.
  fullBuffer,
}

/// The text for [range], read from [session].
///
/// `session.snapshot` is already the viewport window the surface paints, so the visible range costs
/// nothing extra; the full buffer is the one that has to be built.
String transcriptTextFor(ShellSession session, TranscriptRange range) => switch (range) {
  TranscriptRange.visibleScreen => transcriptText(session.snapshot.rows),
  TranscriptRange.fullBuffer => transcriptText(session.emulator.snapshot().rows),
};

class _TranscriptSheet extends StatefulWidget {
  const _TranscriptSheet({required this.session});

  final ShellSession session;

  @override
  State<_TranscriptSheet> createState() => _TranscriptSheetState();
}

class _TranscriptSheetState extends State<_TranscriptSheet> {
  TranscriptRange _range = TranscriptRange.visibleScreen;

  /// Drops the scrollback after confirming, as Kotlin does (`ui/ShellScreen.kt:2508`).
  ///
  /// It sits in this sheet because that is where Kotlin puts it — beside the copy ranges, which is
  /// where someone is already looking at the buffer and deciding what to do with it.
  Future<void> _confirmClearScrollback() async {
    final cleared = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('transcript.clear.dialog'),
        title: const Text('Clear scrollback?'),
        content: const Text(
          'Clear the current terminal scrollback buffer? This removes buffered '
          'terminal output from this session.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('transcript.clear.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('transcript.clear.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (cleared != true || !mounted) return;
    widget.session.clearScrollback();
    // The sheet is showing what was just discarded, so it cannot stay as it is. Rebuilding drops
    // to whatever the live screen still holds.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Read once per build: the session keeps running underneath, and a transcript that changed
    // between the summary and the body would be reporting on two different snapshots.
    final text = transcriptTextFor(widget.session, _range);
    final showingAll = _range == TranscriptRange.fullBuffer;

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
                      Text(
                        showingAll ? 'Full buffer' : 'Visible screen',
                        key: const ValueKey('transcript.title'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
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
                TextButton(
                  key: const ValueKey('transcript.toggleRange'),
                  onPressed: () => setState(
                    () => _range = showingAll
                        ? TranscriptRange.visibleScreen
                        : TranscriptRange.fullBuffer,
                  ),
                  child: Text(
                    showingAll ? 'Visible screen' : 'Full buffer',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  key: const ValueKey('transcript.copyAll'),
                  tooltip: showingAll ? 'Copy the whole buffer' : 'Copy what is on screen',
                  icon: const Icon(Icons.copy_all, size: 20, color: OmniColors.cyan),
                  onPressed: text.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                showingAll ? 'Full buffer copied' : 'Visible screen copied',
                              ),
                            ),
                          );
                        },
                ),
                IconButton(
                  key: const ValueKey('transcript.clearScrollback'),
                  tooltip: 'Clear scrollback',
                  icon: const Icon(Icons.delete_sweep_outlined, size: 20, color: OmniColors.red),
                  onPressed: _confirmClearScrollback,
                ),
                IconButton(
                  tooltip: 'Close',
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
