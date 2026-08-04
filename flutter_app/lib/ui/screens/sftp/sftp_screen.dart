import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/sftp_view_model.dart';
import 'sftp_tabs.dart';

/// The SFTP screen, ported from `SftpScreen` in `ui/SftpScreen.kt`.
///
/// Four sub-tabs: Bookmarks (the jump list), the SFTP browser, network Shares, and the Transfers
/// log. Only the browser needs a reachable SSH host.
class SftpScreen extends StatefulWidget {
  const SftpScreen({super.key});

  @override
  State<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends State<SftpScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SftpViewModel>().start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SftpViewModel>();

    return Column(
      children: [
        // The host bar belongs to the browser only: Transfers and Bookmarks span every endpoint and
        // Shares has its own list, so a host picker there would be misleading.
        if (vm.activeTab == SftpTab.files && vm.browsedServer != null) _HostBar(vm: vm),
        _TabBar(vm: vm),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: switch (vm.activeTab) {
              SftpTab.bookmarks => SftpBookmarksTab(vm: vm),
              SftpTab.files =>
                vm.browsedServer == null ? const _NoOnlineHost() : SftpFilesTab(vm: vm),
              SftpTab.shares => const _SharesNotPorted(),
              SftpTab.transfers => SftpTransfersTab(vm: vm),
            },
          ),
        ),
      ],
    );
  }
}

class _HostBar extends StatelessWidget {
  const _HostBar({required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final server = vm.browsedServer!;
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
        child: Row(
          children: [
            const Icon(Icons.folder_open, size: 18, color: OmniColors.cyan),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const ValueKey('sftp.hostPicker'),
                  isExpanded: true,
                  value: server.id,
                  items: [
                    for (final host in vm.onlineServers)
                      DropdownMenuItem(
                        value: host.id,
                        child: Text(
                          HostDisplay.instance.name(host),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFamily: OmniFonts.mono,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                  onChanged: vm.selectServer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.vm});

  final SftpViewModel vm;

  static const _labels = {
    SftpTab.bookmarks: 'Bookmarks',
    SftpTab.files: 'SFTP',
    SftpTab.shares: 'Shares',
    SftpTab.transfers: 'Transfers',
  };

  @override
  Widget build(BuildContext context) {
    final hasHost = vm.browsedServer != null;
    return SizedBox(
      height: 44,
      child: ListView(
        key: const ValueKey('sftp.tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          for (final tab in SftpTab.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: ChoiceChip(
                  key: ValueKey('sftp.tab.${tab.name}'),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_labels[tab]!, style: const TextStyle(fontSize: 12)),
                      // A running transfer is easy to forget about once you navigate away, so the
                      // count follows you across tabs.
                      if (tab == SftpTab.transfers && vm.transfers.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _CountBadge(count: vm.transfers.length),
                      ],
                    ],
                  ),
                  // Browsing needs a reachable host; the other three do not.
                  onSelected: (tab == SftpTab.files && !hasHost)
                      ? null
                      : (_) => vm.activeTab = tab,
                  selected: vm.activeTab == tab,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
      child: Text(
        '$count',
        style: TextStyle(fontSize: 9, color: scheme.onPrimary),
      ),
    );
  }
}

class _NoOnlineHost extends StatelessWidget {
  const _NoOnlineHost();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('sftp.noHost'),
      child: Text(
        'No online SSH hosts available to browse',
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
      ),
    );
  }
}

class _SharesNotPorted extends StatelessWidget {
  const _SharesNotPorted();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('sftp.shares.notPorted'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lan_outlined, size: 36, color: OmniColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'Network shares are not available in this build yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
