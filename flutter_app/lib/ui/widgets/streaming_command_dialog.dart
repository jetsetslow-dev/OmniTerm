import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/ssh/ssh_transport.dart';
import '../theme/typography.dart';

/// A command owns its popup and cancellation token, independently of tab/target selection.
class StreamingCommandDialog extends StatefulWidget {
  const StreamingCommandDialog({
    super.key,
    required this.title,
    required this.command,
    required this.run,
  });

  final String title;
  final String command;
  final Future<String> Function(
    Future<void> Function(String) onChunk,
    SshCancellationToken cancellation,
  )
  run;

  @override
  State<StreamingCommandDialog> createState() => _StreamingCommandDialogState();
}

class _StreamingCommandDialogState extends State<StreamingCommandDialog> {
  final _cancellation = SshCancellationToken();
  var _running = true;
  var _output = '';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _append(String chunk) {
    final text = _output + chunk;
    _output = text.length > 200000
        ? '[Earlier output truncated]\n${text.substring(text.length - 200000)}'
        : text;
  }

  Future<void> _run() async {
    try {
      final result = await widget.run((chunk) async {
        if (mounted && !_cancellation.isCancelled) setState(() => _append(chunk));
      }, _cancellation);
      if (!mounted) return;
      if (_output.isEmpty) {
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
          if (_output.trim().isEmpty) _output = 'Completed (no output).';
        });
      }
      await _cancellation.close();
    }
  }

  @override
  void dispose() {
    if (_running) _cancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    child: AlertDialog(
      key: const ValueKey('command.stream.dialog'),
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('\$ ${widget.command}', style: const TextStyle(fontFamily: OmniFonts.mono)),
            const SizedBox(height: 12),
            if (_running) const CircularProgressIndicator(),
            Text(_running ? 'Running — output appears below as it arrives.' : 'Command finished.'),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
              child: SingleChildScrollView(
                child: SelectableText(
                  _output,
                  style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_running) _cancellation.cancel();
            Navigator.of(context).pop();
          },
          child: Text(_running ? 'Stop and close' : 'Close'),
        ),
      ],
    ),
  );
}
