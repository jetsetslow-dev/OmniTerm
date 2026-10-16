import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../domain/host_display.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Shows exactly what will run, and where, before it runs.
///
/// Shared by Fleet's broadcast and Monitor's quick scripts. Both are one tap away from executing an
/// arbitrary command on someone's server, and the Kotlin guards both the same way — so this is one
/// dialog rather than two that would eventually warn about different things.
///
/// The hosts are **named, not counted**. "5 hosts" is not something a user can check; a list is.
/// The targets passed in are a snapshot: what was approved is what runs, rather than a group being
/// re-resolved behind the dialog.
Future<bool> confirmRunCommand(
  BuildContext context, {
  required String command,
  required List<Server> targets,
  String? danger,
}) async {
  if (targets.isEmpty || command.trim().isEmpty) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('run.dialog'),
      title: Text('Run on ${targets.length} host${targets.length == 1 ? '' : 's'}?'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '\$ ${command.trim()}',
                key: const ValueKey('run.dialog.command'),
                style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
              ),
              const SizedBox(height: 10),
              for (final target in targets)
                Text(
                  '• ${HostDisplay.instance.name(target)} '
                  '(${HostDisplay.instance.userAtHost(target)})',
                  style: const TextStyle(fontSize: 11),
                ),
              if (danger != null) ...[
                const SizedBox(height: 10),
                Text(
                  '⚠ $danger',
                  key: const ValueKey('run.dialog.danger'),
                  style: const TextStyle(fontSize: 12, color: OmniColors.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('run.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('run.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('Run', style: TextStyle(color: danger != null ? OmniColors.red : null)),
        ),
      ],
    ),
  );

  return confirmed ?? false;
}
