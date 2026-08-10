import 'dart:async';

import '../../widgets/omni_components.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/host_display.dart';
import '../../../domain/network_share_form.dart';
import '../../../domain/sftp_back_action.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/sftp_view_model.dart';
import '../../widgets/back_interceptor.dart';
import '../../widgets/image_preview_overlay.dart';
import 'shares_tab.dart';
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

  /// Back peels one layer of screen state at a time; see [sftpBackAction] for the order.
  ///
  /// Returns true when the press was consumed. The `unawaited` calls are deliberate: the press is
  /// claimed the moment the action is chosen, and making the guard wait on a network listing would
  /// leave Back unresponsive for as long as the remote takes to answer.
  bool _handleBack(SftpViewModel vm) {
    final action = sftpBackAction(
      previewOpen: vm.imagePreview != null,
      onFilesTab: vm.activeTab == SftpTab.files && vm.hasBrowseTarget,
      hasSelection: vm.hasSelection,
      searchResultsShown: vm.searchHits != null,
      path: vm.path,
      shareOpen: vm.browsedShare != null,
    );
    switch (action) {
      case SftpBackAction.none:
        return false;
      case SftpBackAction.closePreview:
        vm.closeImagePreview();
      case SftpBackAction.clearSelection:
        vm.clearSelection();
      case SftpBackAction.clearSearch:
        vm.clearSearchHits();
      case SftpBackAction.goUp:
        unawaited(vm.goUp());
      case SftpBackAction.closeShare:
        unawaited(vm.closeShare());
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SftpViewModel>();

    final preview = vm.imagePreview;

    return BackInterceptor(
      onBack: () => _handleBack(context.read<SftpViewModel>()),
      child: Stack(
        children: [
          Column(
            children: [
              // The host bar belongs to the browser only: Transfers and Bookmarks span every endpoint and
              // Shares has its own list, so a host picker there would be misleading.
              if (vm.activeTab == SftpTab.files && vm.browsedShare != null)
                _ShareBar(vm: vm)
              else if (vm.activeTab == SftpTab.files &&
                  vm.browsedServer != null)
                _HostBar(vm: vm),
              _TabBar(vm: vm),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: switch (vm.activeTab) {
                    SftpTab.bookmarks => SftpBookmarksTab(vm: vm),
                    SftpTab.files =>
                      vm.hasBrowseTarget
                          ? SftpFilesTab(vm: vm)
                          : const _NoOnlineHost(),
                    SftpTab.shares => const SharesTab(),
                    SftpTab.transfers => SftpTransfersTab(vm: vm),
                  },
                ),
              ),
            ],
          ),
          // Over the whole screen, and only while there is something to show. A dismissed preview
          // leaves nothing behind — the bytes go with it.
          if (preview != null)
            Positioned.fill(
              child: ImagePreviewOverlay(
                preview: preview,
                onClose: vm.closeImagePreview,
              ),
            ),
        ],
      ),
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

/// Names the share being browsed, and offers the only way back to hosts.
///
/// A separate bar from [_HostBar] rather than a reused one with a different label: the host picker
/// must not appear here at all, because switching hosts underneath an open share would be a control
/// that looks like it changes what you are looking at and does not.
class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final share = vm.browsedShare!;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('sftp.shareBar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.folder_shared, size: 18, color: OmniColors.cyan),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  share.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                ListenableBuilder(
                  listenable: HostDisplay.instance,
                  builder: (context, _) => Text(
                    shareUri(
                      share,
                      maskedAddress: HostDisplay.instance.sensitive(
                        share.address,
                      ),
                    ),
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            key: const ValueKey('sftp.shareBar.close'),
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Close', style: TextStyle(fontSize: 12)),
            onPressed: vm.closeShare,
          ),
        ],
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
    final hasHost = vm.hasBrowseTarget;
    return SizedBox(
      height: scaledBarHeight(context, 44),
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
                      if (tab == SftpTab.transfers &&
                          vm.transfers.isNotEmpty) ...[
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
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    );
  }
}
