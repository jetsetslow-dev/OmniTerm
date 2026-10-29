import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/app_database.dart';
import '../../data/host_tools.dart';
import '../../data/remote_commands.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/server_credentials.dart';
import '../../l10n/app_localizations.dart';
import '../view_model/app_lock_controller.dart';
import '../view_model/app_state.dart';
import 'action_stream_dialog.dart';
import 'sudo_auth_dialog.dart';

/// Says what installing [tool] on [server] would show, with a button that installs it there and
/// then reads again through [onInstalled]. Every "install this on the host" notice in the app is
/// this one, as Kotlin's `HostToolNotice` (`ui/HostToolNotice.kt`).
class HostToolNotice extends StatelessWidget {
  const HostToolNotice({
    super.key,
    required this.server,
    required this.tool,
    required this.text,
    required this.onInstalled,
    this.fontSize = 11,
  });

  final Server server;
  final HostTool tool;
  final String text;
  final VoidCallback onInstalled;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: fontSize,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: OutlinedButton(
            key: ValueKey('install.${tool.name}'),
            onPressed: () => unawaited(installHostTool(context, server, tool, onInstalled)),
            child: Text(AppLocalizations.of(context).installTool(tool.displayName)),
          ),
        ),
      ],
    );
  }
}

/// Installs [tool] on [server] with its package manager, behind the sudo check, with the output in
/// an [ActionStreamDialog]. Once the tool answers, [onInstalled] reads again whatever was missing,
/// behind the dialog. Either way the dialog stays up with the output and what came of it, and the
/// user closes it, as with the tmux install. Kotlin's `installHostTool`.
Future<void> installHostTool(
  BuildContext context,
  Server server,
  HostTool tool,
  VoidCallback onInstalled,
) async {
  final lock = context.read<AppLockController>();
  if (!await requestSudoAuth(context, lock, hostName: server.name)) return;
  if (!context.mounted) return;
  final ssh = context.read<SshTransport>();
  final repository = context.read<AppState>().repository;
  final l10n = AppLocalizations.of(context);
  Future<SshCredentials> credentials() async => resolveCredentials(
    server,
    keys: await repository.getAllKeys(),
    profiles: await repository.getAllProfiles(),
  );
  final stdin = sudoStdin(server.sudoPassword);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ActionStreamDialog(
      title: l10n.installToolOn(tool.displayName, server.name),
      run: (onChunk, cancellation) async => ssh.execStream(
        await credentials(),
        // No saved password: sudo must refuse at once rather than wait on stdin for one.
        tool.installCommand(withSudoPassword: stdin != null),
        stdin: stdin,
        cancellation: cancellation,
        onChunk: onChunk,
      ),
      afterRun: () async {
        // Checked again rather than trusting the installer's exit code; a check that could not
        // run is not proof the install worked.
        Future<bool> answers() async {
          try {
            return (await ssh.exec(
              await credentials(),
              tool.checkCommand(),
            )).trim().endsWith('yes');
          } catch (_) {
            return false;
          }
        }

        final installed = await answers();
        if (installed) onInstalled();
        return installed
            ? l10n.toolNowInstalledOn(tool.displayName, server.name)
            : l10n.toolStillNotInstalled(tool.displayName, server.name);
      },
    ),
  );
}
