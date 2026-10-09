import 'package:flutter/material.dart';

import '../../data/remote_parsers.dart' show humanBytes;
import '../../domain/transfer_aggregate.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'omni_components.dart';

/// Overall progress across every running transfer.
///
/// Ported from `TransferAggregateBar` in `ui/SftpScreen.kt:2886`. Flutter showed a bar per file and
/// nothing above them, which says whether *a* file is moving but never how far through the batch you
/// are, how fast, or how long is left.
class TransferAggregateBar extends StatelessWidget {
  const TransferAggregateBar({super.key, required this.aggregate});

  final TransferAggregate aggregate;

  @override
  Widget build(BuildContext context) {
    final speed = formatSpeed(aggregate.speedKbps);
    final eta = aggregate.etaSeconds > 0 ? ' · ETA ${formatEta(aggregate.etaSeconds)}' : '';
    final files = aggregate.activeFiles;

    return OmniCard(
      key: const ValueKey('sftp.transfers.aggregate'),
      leftAccent: OmniColors.cyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sync_alt, size: 16, color: OmniColors.cyan),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Transferring $files file${files == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Indeterminate when nothing running has declared a size: a determinate bar pinned at 0%
          // reads as stalled, which is the opposite of what is happening.
          LinearProgressIndicator(
            key: const ValueKey('sftp.transfers.aggregate.bar'),
            value: aggregate.hasKnownTotal ? aggregate.fraction : null,
            color: OmniColors.cyan,
          ),
          const SizedBox(height: 4),
          Text(
            [
                  if (aggregate.hasKnownTotal)
                    '${humanBytes(aggregate.bytesTransferred)} of ${humanBytes(aggregate.totalBytes)}'
                  else
                    humanBytes(aggregate.bytesTransferred),
                  if (speed.isNotEmpty) speed,
                ].join(' · ') +
                eta,
            key: const ValueKey('sftp.transfers.aggregate.detail'),
            style: TextStyle(
              fontSize: 11,
              fontFamily: OmniFonts.mono,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
