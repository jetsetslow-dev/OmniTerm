import 'package:flutter/material.dart';

import '../../domain/terminal_transcript.dart';
import '../../l10n/app_localizations.dart';
import '../theme/typography.dart';
import '../view_model/shell_session.dart';
import 'copy_with_confirmation.dart';

/// The scrollback as selectable text: Kotlin's copy window (`ui/ShellScreen.kt`, the `copyDialog`).
///
/// **The terminal surface paints a grid**, so there is nothing on it to select — which left the one
/// thing people do with terminal output, copy it, impossible. The Kotlin answers this the same way
/// (its PR #69): a long press opens the transcript in a selectable text control, rather than trying
/// to make a canvas behave like a document.
///
/// **Opens on the visible screen, with the full buffer one tap away**, as Kotlin does: the common
/// reason to reach for this is the error currently on screen, and rendering a two-thousand-row
/// scrollback into selectable text on every long press is the expensive case, not the useful one.
/// Clearing the scrollback is not offered here; Kotlin keeps that in the terminal options.
Future<void> openTerminalTranscript(
  BuildContext context,
  ShellSession session, {
  TranscriptRange initialRange = TranscriptRange.visibleScreen,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TranscriptDialog(session: session, initialRange: initialRange),
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

class _TranscriptDialog extends StatefulWidget {
  const _TranscriptDialog({required this.session, required this.initialRange});

  final ShellSession session;
  final TranscriptRange initialRange;

  @override
  State<_TranscriptDialog> createState() => _TranscriptDialogState();
}

class _TranscriptDialogState extends State<_TranscriptDialog> {
  late TranscriptRange _range = widget.initialRange;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggleRange() {
    setState(
      () => _range = _range == TranscriptRange.fullBuffer
          ? TranscriptRange.visibleScreen
          : TranscriptRange.fullBuffer,
    );
    // A new range starts at its top, as Kotlin scrolls its text view back to 0.
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    // Read once per build: the session keeps running underneath.
    final text = transcriptTextFor(widget.session, _range);
    final showingAll = _range == TranscriptRange.fullBuffer;

    return Dialog(
      // Kotlin: `usePlatformDefaultWidth = false`, 96% of the width and 82% of the height.
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 6,
      child: SizedBox(
        width: size.width * 0.96,
        height: size.height * 0.82,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      showingAll ? 'Full buffer' : 'Visible screen',
                      key: const ValueKey('transcript.title'),
                      style: composeBody(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    AppLocalizations.of(context).dragToSelectOrCopyAll,
                    style: composeBody(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('transcript.toggleRange'),
                onPressed: _toggleRange,
                child: Text(showingAll ? 'Show visible screen' : 'Show full buffer'),
              ),
              // A theme surface, not a fixed dark token: with a light theme, onSurface is near-black
              // and a fixed dark pane rendered the text black-on-black (Kotlin's note).
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ColoredBox(
                    color: scheme.surfaceContainerHigh,
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        // Lines wrap to the dialog width, so selection is a vertical drag rather
                        // than chasing text off the right edge.
                        child: SelectableText(
                          text.trim().isEmpty ? 'No terminal text in this range.' : text,
                          key: const ValueKey('transcript.text'),
                          style: TextStyle(
                            fontFamily: OmniFonts.mono,
                            fontSize: 11,
                            height: 1.05,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('transcript.close'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(AppLocalizations.of(context).close),
                    ),
                  ),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('transcript.copyAll'),
                      onPressed: text.trim().isEmpty
                          ? null
                          : () async {
                              final navigator = Navigator.of(context);
                              await copyWithConfirmation(context, text);
                              navigator.pop();
                            },
                      icon: const Icon(Icons.content_copy, size: 18),
                      label: Text(AppLocalizations.of(context).copyAll),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
