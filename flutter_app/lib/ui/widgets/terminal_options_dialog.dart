import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../domain/terminal_soft_input.dart';
import '../shell_state.dart';
import '../view_model/shell_session.dart';
import '../view_model/shell_view_model.dart';
import 'keep_screen_on_feedback.dart';
import 'popup_scroll_behavior.dart';
import 'terminal_transcript_sheet.dart';

/// Keeps the original pane and channel attached to an asynchronous paste request.
Future<String> pasteTerminalText(
  BuildContext context,
  ShellViewModel vm,
  ShellSession session,
  String text, {
  required int connectionRevision,
  required int paneChangeRevision,
  bool requireConfirmation = false,
}) async {
  if (text.isEmpty) return 'Clipboard has no text to paste';
  String? unavailable() {
    if (!identical(vm.current, session) || session.connectionRevision != connectionRevision) {
      return 'Paste skipped: the selected terminal changed.';
    }
    if (session.paneChangeRevision != paneChangeRevision) {
      return 'Paste skipped: the tmux pane changed. Try pasting again.';
    }
    if (session.readOnly) return 'Disable read-only mode before pasting';
    if (!session.isOpen) return 'Paste skipped: the terminal is disconnected.';
    if (!session.isInputPaneReady) {
      return 'Paste skipped: the tmux pane is loading. Try again when it is ready.';
    }
    return null;
  }

  final initialProblem = unavailable();
  if (initialProblem != null) return initialProblem;
  if (requireConfirmation || text.runes.length > softInputPasteThreshold) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('shell.pasteConfirm'),
        title: const Text('Paste into terminal?'),
        content: SingleChildScrollView(
          child: Text(
            '${text.runes.length} characters will be sent to the remote shell. '
            'Pasted lines may execute commands immediately.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Paste'),
          ),
        ],
      ),
    );
    if (confirmed != true) return 'Paste cancelled.';
  }
  if (!context.mounted) return 'Paste skipped: the terminal screen closed.';
  final problem = unavailable();
  if (problem != null) return problem;
  return await vm.pasteTo(
        session,
        text,
        connectionRevision: connectionRevision,
        paneChangeRevision: paneChangeRevision,
      )
      ? 'Sent ${text.runes.length} characters to terminal.'
      : 'Paste failed or was interrupted. Some text may have been sent; check the terminal before retrying.';
}

Future<void> openTerminalOptions(
  BuildContext context,
  ShellViewModel vm,
  ShellSession session,
) async {
  final shell = context.read<ShellState>();
  final focus = FocusManager.instance.primaryFocus;
  final range = await showDialog<TranscriptRange>(
    context: context,
    builder: (_) => _TerminalOptions(vm: vm, session: session, shell: shell),
  );
  if (range != null && context.mounted) {
    await openTerminalTranscript(context, session, initialRange: range);
  }
  if (context.mounted && identical(vm.current, session) && session.isOpen && !session.readOnly) {
    if (focus?.context?.mounted == true) focus!.requestFocus();
  }
}

class _TerminalOptions extends StatefulWidget {
  const _TerminalOptions({required this.vm, required this.session, required this.shell});

  final ShellViewModel vm;
  final ShellSession session;
  final ShellState shell;

  @override
  State<_TerminalOptions> createState() => _TerminalOptionsState();
}

class _TerminalOptionsState extends State<_TerminalOptions> {
  bool _pasting = false;
  String? _pasteResult;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    if (_pasting) return;
    final revision = widget.session.connectionRevision;
    final paneRevision = widget.session.paneChangeRevision;
    setState(() {
      _pasting = true;
      _pasteResult = null;
    });
    String result;
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      result = await pasteTerminalText(
        context,
        widget.vm,
        widget.session,
        clip?.text ?? '',
        connectionRevision: revision,
        paneChangeRevision: paneRevision,
      );
    } catch (error) {
      result = 'Could not paste from clipboard: $error';
    }
    if (!mounted) return;
    setState(() {
      _pasting = false;
      _pasteResult = result;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear scrollback?'),
        content: const SingleChildScrollView(
          child: Text(
            'Clear the current terminal scrollback buffer? This removes buffered '
            'terminal output from this session.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    widget.session.clearScrollback();
    setState(() => _pasteResult = 'Terminal scrollback cleared.');
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _heading(String text) =>
      Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold));

  /// Paste is the primary action, so it stays above any scrolling region.
  List<Widget> _pasteAction(ShellSession session, bool writable) => [
    _heading('Terminal input'),
    FilledButton.icon(
      key: const ValueKey('terminalOptions.paste'),
      onPressed: writable && !_pasting ? _paste : null,
      icon: const Icon(Icons.content_paste, size: 18),
      label: Text(
        session.readOnly ? 'Paste unavailable in read-only mode' : 'Paste from clipboard',
      ),
    ),
    if (_pasting) const LinearProgressIndicator(key: ValueKey('terminalOptions.progress')),
    if (widget.shell.isSettingKeepScreenOn) ...[
      const LinearProgressIndicator(key: ValueKey('terminalOptions.awake.progress')),
      const Text(
        'Updating Keep screen on…',
        style: TextStyle(fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  ];

  /// Explanations and session switches scroll; every action outside this region stays visible.
  Widget _sessionOptions(BuildContext context) {
    final vm = widget.vm;
    final shell = widget.shell;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Flexible(
      child: ScrollConfiguration(
        behavior: const PopupScrollBehavior(),
        child: SingleChildScrollView(
          key: const ValueKey('terminalOptions.scroll'),
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_pasting) const Text('Reading clipboard and preparing paste…'),
              if (_pasteResult != null)
                Text(_pasteResult!, key: const ValueKey('terminalOptions.result')),
              Text(
                'Use this when an incognito keyboard does not expose clipboard history.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              const Divider(),
              _heading('This session'),
              SwitchListTile(
                key: const ValueKey('terminalOptions.swipe'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Swipe-typing',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  vm.smartSwipeInput
                      ? 'On — text streams as you swipe/autocorrect'
                      : 'Off — each keystroke is sent immediately',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                value: vm.smartSwipeInput,
                onChanged: vm.setSmartSwipeRuntime,
              ),
              SwitchListTile(
                key: const ValueKey('terminalOptions.awake'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Keep screen on',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  shell.isKeepScreenOnEnabled
                      ? 'On — screen stays awake in this session'
                      : 'Off — screen may sleep normally',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                value: shell.isKeepScreenOnEnabled,
                onChanged: shell.isSettingKeepScreenOn
                    ? null
                    : (value) => unawaited(shell.setKeepScreenOnDirect(value)),
              ),
              KeepScreenOnFeedback(shell: shell),
            ],
          ),
        ),
      ),
    );
  }

  /// The copy heading is pinned with its range and scrollback actions so a section title is
  /// never separated from the controls it describes.
  List<Widget> _copyActions(BuildContext context, {required bool withDescription}) => [
    _heading('Copy terminal text'),
    if (withDescription)
      Text(
        'Choose the terminal text range to copy.',
        style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    Row(
      children: [
        Expanded(
          child: FilledButton(
            key: const ValueKey('terminalOptions.visible'),
            onPressed: _pasting
                ? null
                : () => Navigator.pop(context, TranscriptRange.visibleScreen),
            child: const Text('Visible screen', textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('terminalOptions.full'),
            onPressed: _pasting ? null : () => Navigator.pop(context, TranscriptRange.fullBuffer),
            child: const Text('Full buffer', textAlign: TextAlign.center),
          ),
        ),
      ],
    ),
    Row(
      children: [
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('terminalOptions.clear'),
            onPressed: _pasting ? null : _clear,
            child: const Text('Clear scrollback', textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 6),
        TextButton(
          key: const ValueKey('terminalOptions.cancel'),
          onPressed: _pasting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  ];

  static List<Widget> _spaced(List<Widget> children) => [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(height: 6),
      children[i],
    ],
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.vm, widget.session, widget.shell]),
    builder: (context, _) {
      final session = widget.session;
      final vm = widget.vm;
      final writable =
          identical(vm.current, session) &&
          session.isOpen &&
          !session.readOnly &&
          session.isInputPaneReady;
      final size = MediaQuery.sizeOf(context);
      // Landscape has the width for two columns; stacking everything there would squeeze the
      // session options behind the copy actions. Matches Kotlin's terminal options layout.
      final wide = size.width > size.height;
      final Widget body;
      if (wide) {
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _spaced([..._pasteAction(session, writable), _sessionOptions(context)]),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _spaced(_copyActions(context, withDescription: false)),
              ),
            ),
          ],
        );
      } else {
        body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _spaced([
            ..._pasteAction(session, writable),
            _sessionOptions(context),
            const Divider(height: 1),
            ..._copyActions(context, withDescription: true),
          ]),
        );
      }
      return PopScope(
        canPop: !_pasting,
        child: Dialog(
          key: const ValueKey('terminalOptions.dialog'),
          // No fixed height cap: the card may use the whole padded window so every option fits
          // without scrolling on ordinary phones.
          insetPadding: EdgeInsets.symmetric(horizontal: 18, vertical: wide ? 8 : 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [Flexible(child: body)],
                  )
                : body,
          ),
        ),
      );
    },
  );
}
