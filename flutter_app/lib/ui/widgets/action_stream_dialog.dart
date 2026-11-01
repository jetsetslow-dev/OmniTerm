import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/ssh/ssh_transport.dart';
import '../../l10n/app_localizations.dart';
import '../theme/typography.dart';
import 'copy_with_confirmation.dart';
import 'stream_output_box.dart';

/// Kotlin's longest kept action output (`ACTION_STREAM_MAX_CHARS`); older output drops off the top.
const _maxChars = 200000;

/// Live output of a remote action, as Kotlin's `ActionStreamDialog` (`ui/AppUi.kt`): the title with
/// a spinner while it runs, the output as it arrives, Copy, and Cancel (while running) or Close.
///
/// It stays up once the command ends, for the user to read and close. [afterRun] runs then (not
/// after a cancel) and may add a line below the output, such as whether an install took.
class ActionStreamDialog extends StatefulWidget {
  const ActionStreamDialog({super.key, required this.title, required this.run, this.afterRun});

  final String title;
  final Future<String> Function(
    Future<void> Function(String chunk) onChunk,
    SshCancellationToken cancellation,
  )
  run;
  final Future<String?> Function()? afterRun;

  @override
  State<ActionStreamDialog> createState() => _ActionStreamDialogState();
}

class _ActionStreamDialogState extends State<ActionStreamDialog> {
  final _cancellation = SshCancellationToken();
  var _running = true;
  var _output = '';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _append(String text) {
    final appended = _output + text;
    _output = appended.length > _maxChars
        ? appended.substring(appended.length - _maxChars)
        : appended;
  }

  Future<void> _run() async {
    try {
      final result = await widget.run((chunk) async {
        if (mounted && !_cancellation.isCancelled) setState(() => _append(chunk));
      }, _cancellation);
      if (!mounted) return;
      if (_output.trim().isEmpty) {
        _output = result;
      } else if (result.startsWith('SSH Error:') && !_output.contains(result)) {
        _append('\n$result');
      }
    } catch (error) {
      if (mounted) _append('\nCommand failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          // Make zero-output actions read as clearly finished.
          if (_output.trim().isEmpty) _output = 'Done (no output)';
        });
      }
      await _cancellation.close();
    }
    final after = widget.afterRun;
    if (after == null || !mounted || _cancellation.isCancelled) return;
    final line = await after();
    if (line != null && mounted) setState(() => _output = '${_output.trimRight()}\n\n$line');
  }

  @override
  void dispose() {
    if (_running) _cancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      // While still streaming, back is ignored so the output is not lost; Cancel stops it.
      canPop: !_running,
      child: AlertDialog(
        key: const ValueKey('actionStream.dialog'),
        title: Row(
          children: [
            if (_running) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                widget.title.isEmpty ? 'Output' : widget.title,
                style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 14),
              ),
            ),
          ],
        ),
        // White on black, as Kotlin's terminal look for command output.
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ColoredBox(
            color: Colors.black,
            child: Theme(
              data: Theme.of(context).copyWith(
                colorScheme: Theme.of(
                  context,
                ).colorScheme.copyWith(onSurface: Colors.white, onSurfaceVariant: Colors.grey),
              ),
              child: StreamOutputBox(
                key: const ValueKey('actionStream.output'),
                lines: _output.isEmpty ? const [] : _output.split('\n'),
                placeholder: _running ? l10n.running2 : null,
                padding: const EdgeInsets.all(8),
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            key: const ValueKey('actionStream.copy'),
            onPressed: _output.trim().isEmpty ? null : () => copyWithConfirmation(context, _output),
            icon: const Icon(Icons.content_copy, size: 16),
            label: Text(l10n.copy),
          ),
          TextButton(
            key: const ValueKey('actionStream.close'),
            onPressed: () {
              if (_running) _cancellation.cancel();
              Navigator.of(context).pop();
            },
            child: Text(_running ? l10n.cancel : l10n.close),
          ),
        ],
      ),
    );
  }
}
