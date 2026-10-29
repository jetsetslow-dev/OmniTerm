import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../../l10n/app_localizations.dart';
import '../../view_model/network_view_model.dart';
import '../../widgets/stream_output_box.dart';

/// Pings or traces [server] from this device in a pop-up, as Kotlin's `HostCheckDialog`. Opened
/// from the host's card or its ⋮ menu whatever its status; closing it stops the check.
Future<void> showHostCheckDialog(
  BuildContext context,
  NetworkViewModel network,
  Server server,
  HostCheck kind,
) async {
  unawaited(network.runHostCheck(server, kind));
  await showDialog<void>(
    context: context,
    builder: (_) => _HostCheckDialog(network: network),
  );
  network.closeHostCheck();
}

final _ipv4Address = RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b');

class _HostCheckDialog extends StatelessWidget {
  const _HostCheckDialog({required this.network});

  final NetworkViewModel network;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([network, HostDisplay.instance]),
    builder: (context, _) {
      final request = network.hostCheck;
      if (request == null) return const SizedBox.shrink();
      final server = request.server;
      final display = HostDisplay.instance;
      final scheme = Theme.of(context).colorScheme;
      final ping = request.kind == HostCheck.ping;
      // The address is masked like everywhere else while sensitive info is hidden.
      final lines = [
        for (final line in network.hostCheckLines)
          display.hideSensitiveInfo
              ? line.replaceAll(server.host, display.host(server)).replaceAll(_ipv4Address, '•••')
              : line,
      ];
      return AlertDialog(
        key: const ValueKey('hosts.check.dialog'),
        title: Text(
          ping ? 'Ping ${display.name(server)}' : 'Traceroute to ${display.name(server)}',
        ),
        // Full width, so the dialog never asks the output's lazy list how wide it would like to be.
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ping
                    ? AppLocalizations.of(context).pingsAreSentFromThisDevice
                    : AppLocalizations.of(context).tracesEachNetworkHopFromThis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120, maxHeight: 320),
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: StreamOutputBox(
                    key: const ValueKey('hosts.check.output'),
                    lines: lines,
                    isFailure: ping ? isPingFailureLine : isTracerouteFailureLine,
                    placeholder: 'Running…',
                    padding: const EdgeInsets.all(8),
                    shrinkWrap: true,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('hosts.check.close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (network.hostCheckRunning)
            TextButton(
              key: const ValueKey('hosts.check.stop'),
              onPressed: network.stopHostCheck,
              child: const Text('Stop'),
            )
          else
            TextButton(
              key: const ValueKey('hosts.check.again'),
              onPressed: () => network.runHostCheck(server, request.kind),
              child: const Text('Run again'),
            ),
        ],
      );
    },
  );
}
