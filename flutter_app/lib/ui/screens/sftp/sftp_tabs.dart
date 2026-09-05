import 'package:flutter/material.dart';

import '../../../data/remote_commands.dart';
import '../../../data/remote_models.dart';
import '../../../data/app_database.dart';
import '../../../data/remote_parsers.dart';
import '../../../domain/endpoint_bookmark.dart';
import '../../../domain/image_preview.dart';
import '../../../domain/remote_path.dart';
import '../../../domain/sftp_sort.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'package:provider/provider.dart';
import '../../../platform/device_file_store.dart';
import '../../view_model/app_lock_controller.dart';
import '../../widgets/sudo_auth_dialog.dart';
import '../../view_model/sftp_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/transfer_aggregate_bar.dart';
import 'file_editor_sheet.dart';

/// Saved paths for the current host.
class SftpBookmarksTab extends StatefulWidget {
  const SftpBookmarksTab({super.key, required this.vm});

  final SftpViewModel vm;

  @override
  State<SftpBookmarksTab> createState() => _SftpBookmarksTabState();
}

class _SftpBookmarksTabState extends State<SftpBookmarksTab> {
  @override
  void initState() {
    super.initState();
    // Bookmarks span every endpoint, so a star set in the browser — or on another host entirely —
    // has to be picked up on entry rather than only when this view model was built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.vm.loadAllBookmarks();
    });
  }

  Future<void> _edit({EndpointBookmark? prefill, EndpointBookmark? replacing}) async {
    final vm = widget.vm;
    final result = await showDialog<_BookmarkDraft>(
      context: context,
      builder: (_) => _BookmarkEditorDialog(
        servers: vm.bookmarkServers,
        shares: vm.bookmarkShares,
        prefill: prefill,
        isEdit: replacing != null,
      ),
    );
    if (result == null) return;
    await vm.saveEndpointBookmark(
      serverId: result.serverId,
      shareId: result.shareId,
      path: result.path,
      replacing: replacing,
    );
  }

  Future<void> _delete(EndpointBookmark bookmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.bookmark.remove.dialog'),
        title: const Text('Remove bookmark?'),
        // Names the endpoint as well as the path: the same path is bookmarked on several hosts, and
        // "Remove /var/log?" does not say which one is about to go.
        content: Text('Remove ${bookmark.path} on ${bookmark.endpointName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('sftp.bookmark.remove.confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.vm.removeEndpointBookmark(bookmark);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vm = widget.vm;
    final bookmarks = vm.allBookmarks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Quick access bookmarks — every host and share.',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('sftp.bookmarks.add'),
              onPressed: () => _edit(),
              icon: const Icon(Icons.bookmark_add, size: 16),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: bookmarks.isEmpty
              ? Center(
                  key: const ValueKey('sftp.bookmarks.empty'),
                  child: Text(
                    'No bookmarks yet — star a folder while browsing, or add one here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                )
              : ListView.separated(
                  key: const ValueKey('sftp.bookmarks.list'),
                  itemCount: bookmarks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) =>
                      _BookmarkRow(bookmark: bookmarks[index], tab: this),
                ),
        ),
      ],
    );
  }
}

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({required this.bookmark, required this.tab});

  final EndpointBookmark bookmark;
  final _SftpBookmarksTabState tab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vm = tab.widget.vm;
    final available = vm.bookmarkIsAvailable(bookmark);
    final key = bookmark.isShare ? 'share:${bookmark.shareId}' : 'host:${bookmark.serverId}';

    return Opacity(
      // Dimmed rather than hidden: a bookmark on an offline host is still worth seeing, and
      // removing the row would read as the bookmark having been lost.
      opacity: available ? 1 : 0.38,
      child: OmniCard(
        key: ValueKey('sftp.bookmark.$key.${bookmark.path}'),
        onTap: available ? () => vm.openEndpointBookmark(bookmark) : null,
        child: Row(
          children: [
            Icon(
              bookmark.isShare ? Icons.lan : Icons.bookmark,
              size: 16,
              color: available ? OmniColors.amber : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bookmark.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: OmniFonts.mono,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    // The endpoint is named on every row because the same path exists on several
                    // machines and opening the wrong one is the mistake this tab invites.
                    available ? bookmark.endpointName : '${bookmark.endpointName} · offline',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: bookmark.isShare ? OmniColors.purple : OmniColors.cyan,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('sftp.bookmark.$key.${bookmark.path}.edit'),
              tooltip: 'Edit bookmark',
              icon: const Icon(Icons.edit, size: 16),
              onPressed: () => tab._edit(prefill: bookmark, replacing: bookmark),
            ),
            IconButton(
              key: ValueKey('sftp.bookmark.$key.${bookmark.path}.clone'),
              tooltip: 'Clone bookmark',
              icon: const Icon(Icons.content_copy, size: 16),
              onPressed: () => tab._edit(prefill: bookmark),
            ),
            IconButton(
              key: ValueKey('sftp.bookmark.$key.${bookmark.path}.remove'),
              tooltip: 'Delete bookmark',
              icon: const Icon(Icons.delete, size: 16, color: OmniColors.red),
              onPressed: () => tab._delete(bookmark),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the editor returns: an endpoint and a path.
class _BookmarkDraft {
  const _BookmarkDraft({this.serverId, this.shareId, required this.path});

  final int? serverId;
  final int? shareId;
  final String path;
}

/// Add, edit or clone a bookmark against an explicitly chosen endpoint.
///
/// The endpoint starts **unselected** on a plain add. Defaulting to whichever host the browser
/// happens to be on would file bookmarks against the wrong machine without the user ever seeing the
/// choice — and a bookmark on the wrong host is silently useless rather than visibly wrong.
class _BookmarkEditorDialog extends StatefulWidget {
  const _BookmarkEditorDialog({
    required this.servers,
    required this.shares,
    required this.prefill,
    required this.isEdit,
  });

  final List<Server> servers;
  final List<NetworkShare> shares;
  final EndpointBookmark? prefill;
  final bool isEdit;

  @override
  State<_BookmarkEditorDialog> createState() => _BookmarkEditorDialogState();
}

class _BookmarkEditorDialogState extends State<_BookmarkEditorDialog> {
  late final TextEditingController _path = TextEditingController(text: widget.prefill?.path ?? '');
  late int? _serverId = widget.prefill?.serverId;
  late int? _shareId = widget.prefill?.shareId;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  String get _endpointLabel {
    if (_serverId != null) {
      for (final server in widget.servers) {
        if (server.id == _serverId) return server.name;
      }
      return 'Unknown host';
    }
    if (_shareId != null) {
      for (final share in widget.shares) {
        if (share.id == _shareId) {
          return SftpViewModel.shareEndpointLabel(share);
        }
      }
      return 'Unknown share';
    }
    return 'Select server or share…';
  }

  bool get _canSave => (_serverId != null || _shareId != null) && _path.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final title = widget.isEdit
        ? 'Edit bookmark'
        : widget.prefill != null
        ? 'Clone bookmark'
        : 'Add bookmark';

    return AlertDialog(
      key: const ValueKey('sftp.bookmark.editor'),
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PopupMenuButton<String>(
            key: const ValueKey('sftp.bookmark.editor.endpoint'),
            onSelected: (value) => setState(() {
              final id = int.parse(value.substring(value.indexOf(':') + 1));
              final isShare = value.startsWith('share:');
              // One endpoint at a time — clearing the other is what makes the choice exclusive.
              _serverId = isShare ? null : id;
              _shareId = isShare ? id : null;
            }),
            itemBuilder: (_) => [
              for (final server in widget.servers)
                PopupMenuItem(
                  value: 'host:${server.id}',
                  child: Row(
                    children: [
                      const Icon(Icons.dns, size: 16),
                      const SizedBox(width: 8),
                      Expanded(child: Text(server.name)),
                    ],
                  ),
                ),
              for (final share in widget.shares)
                PopupMenuItem(
                  value: 'share:${share.id}',
                  child: Row(
                    children: [
                      const Icon(Icons.lan, size: 16),
                      const SizedBox(width: 8),
                      Expanded(child: Text(SftpViewModel.shareEndpointLabel(share))),
                    ],
                  ),
                ),
            ],
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Endpoint',
                border: OutlineInputBorder(),
              ),
              child: Row(
                children: [
                  Icon(_shareId != null ? Icons.lan : Icons.dns, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_endpointLabel, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('sftp.bookmark.editor.path'),
            controller: _path,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Path', border: OutlineInputBorder()),
            style: const TextStyle(fontFamily: OmniFonts.mono),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('sftp.bookmark.editor.save'),
          onPressed: _canSave
              ? () => Navigator.of(context).pop(
                  _BookmarkDraft(serverId: _serverId, shareId: _shareId, path: _path.text.trim()),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The remote file browser.
class SftpFilesTab extends StatelessWidget {
  const SftpFilesTab({super.key, required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone in landscape at the largest supported text size can leave less than 80 logical
        // pixels below the app chrome. Putting the path and toolbar beside one another preserves
        // both controls and the file list instead of overflowing before the list gets any height.
        final compactHeader = constraints.maxWidth >= 600 && constraints.maxHeight < 120;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Everything above the listing is one block with a ceiling. Side-by-side controls alone
            // were not enough: on the API-32 phone in landscape at 200% text even the compact row
            // needs more height than the body has, and a Column child with no ceiling overflows
            // rather than yielding. Capping the block at 55% of the body and letting it scroll
            // inside that keeps both the controls and a usable listing at any text size, and costs
            // nothing at ordinary sizes where the block is shorter than the cap.
            ConstrainedBox(
              constraints: BoxConstraints(
                // Less the 6px gap below, which is outside this block: taking the fraction of the
                // raw height leaves the gap unaccounted for and the Column overflows by it.
                maxHeight: ((constraints.maxHeight - 6) * 0.55).clamp(0.0, double.infinity),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (compactHeader)
                      Row(
                        children: [
                          Expanded(child: _Breadcrumbs(vm: vm)),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: _Toolbar(vm: vm)),
                        ],
                      )
                    else ...[
                      _Breadcrumbs(vm: vm),
                      _Toolbar(vm: vm),
                    ],
                    if (vm.loading) const LinearProgressIndicator(minHeight: 2),
                    if (vm.status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: OmniCard(
                          key: const ValueKey('sftp.status'),
                          leftAccent: OmniColors.green,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(vm.status!, style: const TextStyle(fontSize: 12)),
                              ),
                              IconButton(
                                tooltip: 'Dismiss',
                                key: const ValueKey('sftp.status.dismiss'),
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: vm.dismissStatus,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (vm.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: OmniCard(
                          key: const ValueKey('sftp.error'),
                          leftAccent: OmniColors.red,
                          child: SelectionArea(
                            child: Text(
                              vm.error!,
                              style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Search results take the listing's place while they exist, because they answer a different
            // question than "what is in this folder" and mixing the two would make neither readable.
            if (vm.searchHits != null) Expanded(child: _SearchResults(vm: vm)),
            if (vm.searchHits == null)
              Expanded(
                child: vm.visibleEntries.isEmpty
                    // "Not read yet" is not "nothing here". The first listing of a host includes the
                    // TCP connect, the handshake, the auth and opening the SFTP subsystem, and a
                    // browser that says "This directory is empty" throughout that is stating something
                    // false about the user's files — measured on a real host, where the claim stood for
                    // seconds before the listing landed. The 2px bar above is not a correction: it sits
                    // in the toolbar while the body asserts the opposite.
                    ? Center(
                        key: ValueKey(vm.loading ? 'sftp.loading' : 'sftp.empty'),
                        child: Text(
                          vm.loading
                              ? 'Listing…'
                              // "Nothing matched" and "nothing here" are different facts.
                              : vm.searchText.trim().isNotEmpty
                              ? 'Nothing matches your search'
                              : 'This directory is empty',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                        ),
                      )
                    : ListView.separated(
                        key: const ValueKey('sftp.list'),
                        itemCount: vm.visibleEntries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 4),
                        itemBuilder: (context, index) =>
                            _EntryRow(vm: vm, entry: vm.visibleEntries[index]),
                      ),
              ),
          ],
        );
      },
    );
  }
}

class _Breadcrumbs extends StatefulWidget {
  const _Breadcrumbs({required this.vm});

  final SftpViewModel vm;

  @override
  State<_Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<_Breadcrumbs> {
  /// The typed address box, replacing the crumbs while open.
  ///
  /// Local rather than on the view model: it is half-finished text, and it must not survive a host
  /// switch or reappear when the user comes back to the tab.
  TextEditingController? _editing;

  void _startEditing() {
    setState(() {
      // Prefilled with where you are, so the common edit is appending or trimming a segment rather
      // than retyping the whole path.
      _editing = TextEditingController(text: widget.vm.path)
        ..selection = TextSelection.collapsed(offset: widget.vm.path.length);
    });
  }

  void _stopEditing() {
    _editing?.dispose();
    setState(() => _editing = null);
  }

  Future<void> _go() async {
    final typed = _editing?.text ?? '';
    final target = resolveTypedPath(current: widget.vm.path, typed: typed);
    _stopEditing();
    // Null is a cleared box — a change of mind, not a request to go to the root.
    if (target != null) await widget.vm.openPath(target);
  }

  @override
  void dispose() {
    _editing?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final scheme = Theme.of(context).colorScheme;
    final trail = vm.breadcrumbTrail;
    if (trail.isEmpty) return const SizedBox.shrink();

    final editing = _editing;
    if (editing != null) {
      return SizedBox(
        height: 40,
        child: TextField(
          key: const ValueKey('sftp.pathInput'),
          controller: editing,
          autofocus: true,
          // Go rather than Done: the keyboard's action key navigates, so a path can be typed and
          // opened without reaching for the check.
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _go(),
          style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.folder_open, size: 16, color: OmniColors.amber),
            prefixIconConstraints: const BoxConstraints(minWidth: 30),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('sftp.pathInput.go'),
                  tooltip: 'Go to path',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.check, size: 16, color: OmniColors.cyan),
                  onPressed: _go,
                ),
                IconButton(
                  key: const ValueKey('sftp.pathInput.cancel'),
                  tooltip: 'Cancel path edit',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: _stopEditing,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 32,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('sftp.home'),
            tooltip: 'Go to home folder',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.home, size: 16),
            // An empty target is what resolves the remote home, which is not a path this screen can
            // know in advance — it comes from the server.
            onPressed: () => vm.openPath(''),
          ),
          IconButton(
            key: const ValueKey('sftp.up'),
            tooltip: 'Up one level',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.arrow_upward, size: 16),
            onPressed: vm.path == '/' ? null : vm.goUp,
          ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('sftp.breadcrumbs'),
              scrollDirection: Axis.horizontal,
              // Reversed so the deepest crumb — the one you are in — stays visible on a narrow
              // screen instead of scrolling off the right edge.
              reverse: true,
              itemCount: trail.length,
              itemBuilder: (context, index) {
                final crumb = trail[trail.length - 1 - index];
                final isCurrent = crumb.path == vm.path;
                return Center(
                  child: TextButton(
                    key: ValueKey('sftp.crumb.${crumb.path}'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: isCurrent ? null : () => vm.openPath(crumb.path),
                    child: Text(
                      crumb.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: OmniFonts.mono,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: const ValueKey('sftp.editPath'),
            tooltip: 'Edit path',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.edit, size: 16),
            onPressed: _startEditing,
          ),
          IconButton(
            key: const ValueKey('sftp.bookmarkToggle'),
            tooltip: vm.isBookmarked(vm.path) ? 'Remove bookmark' : 'Bookmark this folder',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Icon(
              vm.isBookmarked(vm.path) ? Icons.bookmark : Icons.bookmark_border,
              size: 16,
              color: vm.isBookmarked(vm.path) ? OmniColors.amber : null,
            ),
            onPressed: vm.path.isEmpty ? null : () => vm.toggleBookmark(vm.path),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatefulWidget {
  const _Toolbar({required this.vm});

  final SftpViewModel vm;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  late final TextEditingController _search = TextEditingController(text: widget.vm.searchText);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final search = SizedBox(
      height: 38,
      child: TextField(
        key: const ValueKey('sftp.search'),
        controller: _search,
        // setState as well as the view model: the "search this host" button beside it is
        // enabled by whether anything has been typed, and a controller alone does not rebuild.
        onChanged: (value) => setState(() => vm.searchText = value),
        style: const TextStyle(fontSize: 13),
        decoration: omniInputDecoration(
          context,
          hintText: 'Filter this folder',
          prefixIcon: const Icon(Icons.search, size: 18),
        ),
      ),
    );
    final actions = <Widget>[
      // The escalation from the filter beside it: when what you want is not in this folder, the
      // next question is "is it on this host at all". A share answers the same question by being
      // walked, since it has no shell to run `find` on.
      if (vm.canSearch)
        IconButton(
          key: const ValueKey('sftp.searchHost'),
          tooltip: vm.canSearchShare ? 'Search this share' : 'Search this host',
          icon: const Icon(Icons.travel_explore, size: 18, color: OmniColors.cyan),
          onPressed: vm.isSearching || _search.text.trim().isEmpty
              ? null
              : () =>
                    vm.canSearchShare ? vm.searchShare(_search.text) : vm.searchHost(_search.text),
        ),
      if (vm.hasBrowseTarget)
        IconButton(
          key: const ValueKey('sftp.upload'),
          tooltip: 'Upload files from device',
          icon: const Icon(Icons.upload_file, size: 18),
          onPressed: vm.loading ? null : () => _uploadFromDevice(context, vm),
        ),
      if (vm.canUseSudo)
        IconButton(
          key: const ValueKey('sftp.sudo'),
          tooltip: vm.sudoMode ? 'Reading and writing as root' : 'Read and write as root',
          icon: Icon(
            vm.sudoMode ? Icons.shield : Icons.shield_outlined,
            size: 18,
            // Red when on, because the difference between the two states is who you are on
            // someone else's machine.
            color: vm.sudoMode ? OmniColors.red : null,
          ),
          onPressed: () => vm.sudoMode ? vm.sudoMode = false : _confirmSudo(context, vm),
        ),
      IconButton(
        key: const ValueKey('sftp.toggleHidden'),
        tooltip: vm.showHidden ? 'Hide dotfiles' : 'Show dotfiles',
        icon: Icon(
          vm.showHidden ? Icons.visibility : Icons.visibility_off,
          size: 18,
          color: vm.showHidden ? OmniColors.cyan : null,
        ),
        onPressed: () => vm.showHidden = !vm.showHidden,
      ),
      PopupMenuButton<SftpSortOption>(
        key: const ValueKey('sftp.sort'),
        tooltip: 'Sort',
        icon: Icon(
          Icons.sort,
          size: 18,
          color: vm.sortOption != SftpSortOption.nameAsc ? OmniColors.cyan : null,
        ),
        onSelected: (option) => vm.sortOption = option,
        itemBuilder: (_) => [
          for (final option in SftpSortOption.values)
            PopupMenuItem(
              value: option,
              child: Text(option.label, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
      IconButton(
        key: const ValueKey('sftp.newFolder'),
        tooltip: 'New folder',
        icon: const Icon(Icons.create_new_folder_outlined, size: 18),
        onPressed: () => _promptNewFolder(context, vm),
      ),
      IconButton(
        key: const ValueKey('sftp.refresh'),
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 18),
        onPressed: vm.loading ? null : vm.refresh,
      ),
      IconButton(
        key: const ValueKey('sftp.selectAll'),
        tooltip: 'Select all',
        icon: const Icon(Icons.select_all, size: 18),
        onPressed: vm.canSelectAllVisible ? vm.selectAllVisible : null,
      ),
      if (vm.hasSelection)
        IconButton(
          key: const ValueKey('sftp.clearSelection'),
          tooltip: 'Clear selection',
          icon: const Icon(Icons.deselect, size: 18),
          onPressed: vm.clearSelection,
        ),
      if (vm.canBatchDownload)
        IconButton(
          key: const ValueKey('sftp.downloadSelected'),
          tooltip: 'Download selected files',
          icon: const Icon(Icons.download, size: 18),
          onPressed: () => _downloadSelected(context, vm),
        ),
      if (vm.hasSelection)
        PopupMenuButton<String>(
          key: const ValueKey('sftp.clipboard.stage'),
          tooltip: 'Copy or move selected',
          icon: const Icon(Icons.content_copy, size: 18, color: OmniColors.cyan),
          onSelected: (action) => _stageClipboard(context, vm, move: action == 'move'),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'copy', child: Text('Copy selected')),
            PopupMenuItem(value: 'move', child: Text('Move selected')),
          ],
        ),
      if (vm.hasClipboard)
        IconButton(
          key: const ValueKey('sftp.clipboard.paste'),
          tooltip: '${vm.clipboardSummary} into this folder',
          icon: const Icon(Icons.content_paste, size: 18, color: OmniColors.green),
          onPressed: vm.loading ? null : () => _pasteClipboard(context, vm),
        ),
      if (vm.hasSelection && vm.canArchive)
        PopupMenuButton<String>(
          key: const ValueKey('sftp.archiveSelected'),
          tooltip: 'Compress selected',
          icon: const Icon(Icons.archive_outlined, size: 18),
          onSelected: (format) => _createArchive(context, vm, format),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'zip', child: Text('ZIP (.zip)')),
            PopupMenuItem(value: 'tar.gz', child: Text('Gzipped tar (.tar.gz)')),
            PopupMenuItem(value: 'tar', child: Text('Tar (.tar)')),
            PopupMenuItem(value: '7z', child: Text('7-Zip (.7z, needs 7z on host)')),
          ],
        ),
      if (vm.hasSelection)
        IconButton(
          key: const ValueKey('sftp.deleteSelected'),
          tooltip: 'Delete selected',
          icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
          onPressed: () => _confirmDelete(context, vm, vm.selectedEntries),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 600) {
          return Row(
            children: [
              Expanded(child: search),
              ...actions,
            ],
          );
        }
        // Seven always-available actions cannot coexist with a useful search field at 360dp.
        // Keep the search visible and make only the action strip horizontally scrollable.
        return Row(
          children: [
            Expanded(flex: 2, child: search),
            const SizedBox(width: 4),
            Expanded(
              flex: 3,
              child: SingleChildScrollView(
                key: const ValueKey('sftp.toolbarActions'),
                scrollDirection: Axis.horizontal,
                child: Row(children: actions),
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _stageClipboard(BuildContext context, SftpViewModel vm, {required bool move}) async {
  if (vm.selectedTransferNeedsWarning) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.largeTransfer.dialog'),
        title: const Text('Large transfer'),
        content: const Text(
          'This selection exceeds the warning threshold configured in Settings. '
          'Cross-host transfers pass through this device and may take a while.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  vm.stageSelected(move: move);
}

Future<void> _pasteClipboard(BuildContext context, SftpViewModel vm) async {
  // The standing answer, restored from `cross_paste_recurse`. Kotlin keeps this as a checkbox in the
  // clipboard bar rather than a prompt, so a user who always wants folder contents says so once.
  var recurse = vm.recurseFolders;
  if (vm.clipboardContainsFolders && !recurse) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.recursiveCopy.dialog'),
        title: const Text('Copy folders recursively?'),
        content: const Text(
          'Every file and subfolder will be transferred through this device. '
          'Any name that already exists is checked first, and you decide what happens to it.\n\n'
          'This choice is remembered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Copy folders'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    recurse = true;
    // Only a yes is remembered. Storing a "no" would be storing a cancellation, and the next paste
    // would silently refuse to carry folders with nothing on screen explaining why.
    await vm.setRecurseFolders(true);
  }
  // Scans the destination first: anything that already exists comes back for a decision instead of
  // being silently renamed, which is what this used to do to every clash.
  await vm.beginPaste(recurseFolders: recurse);
  if (!context.mounted || vm.pasteConflicts.isEmpty) return;

  final proceed = await showDialog<bool>(
    context: context,
    builder: (_) => _PasteConflictDialog(vm: vm),
  );
  if (proceed == true) {
    await vm.confirmPasteConflicts();
  } else {
    vm.cancelPasteConflicts();
  }
}

/// Per-item resolution for paste name clashes, ported from `PasteConflictDialog` in
/// `ui/SftpScreen.kt`.
///
/// The verdict on each row comes from comparing **content** — size, then a digest when the sizes
/// match — never from name, size and timestamp, which a copy tool reproduces exactly on different
/// bytes. When the content could not be compared the dialog says so plainly rather than presenting
/// an unverified guess as though it were a real comparison.
class _PasteConflictDialog extends StatefulWidget {
  const _PasteConflictDialog({required this.vm});

  final SftpViewModel vm;

  @override
  State<_PasteConflictDialog> createState() => _PasteConflictDialogState();
}

class _PasteConflictDialogState extends State<_PasteConflictDialog> {
  static String _actionLabel(ConflictAction action) => switch (action) {
    ConflictAction.overwrite => 'Overwrite',
    ConflictAction.skip => 'Skip',
    ConflictAction.keepBoth => 'Keep both',
  };

  String _detail(TransferConflict c) => switch (c.verdict) {
    ConflictVerdict.directory =>
      'Folder — contents merge into the existing folder rather than replacing it',
    ConflictVerdict.identical =>
      'Identical content (checksums match) — overwriting changes nothing',
    ConflictVerdict.different =>
      'Different content — ${humanBytes(c.sourceSize)} vs ${humanBytes(c.destSize)} at destination',
    ConflictVerdict.unknown =>
      'Not verified — no checksum tool on this host; '
          '${humanBytes(c.sourceSize)} vs ${humanBytes(c.destSize)} at destination',
  };

  @override
  Widget build(BuildContext context) {
    final conflicts = widget.vm.pasteConflicts;
    return AlertDialog(
      key: const ValueKey('sftp.conflict.dialog'),
      title: Text('${conflicts.length} item${conflicts.length == 1 ? '' : 's'} already exist'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.vm.conflictsUnverified)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'This host has no checksum tool (sha256sum/shasum/md5sum/cksum), so items '
                  'marked "Not verified" could NOT be compared by content. They may or may not '
                  'differ — matching sizes and dates do not prove files are the same.',
                  key: ValueKey('sftp.conflict.unverified'),
                  style: TextStyle(fontSize: 11, color: OmniColors.amber),
                ),
              ),
            Row(
              children: [
                const Text(
                  'Apply to all:',
                  style: TextStyle(fontSize: 11, color: OmniColors.textMuted),
                ),
                for (final action in ConflictAction.values)
                  TextButton(
                    key: ValueKey('sftp.conflict.all.${action.name}'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => setState(() => widget.vm.setAllPasteConflictActions(action)),
                    child: Text(_actionLabel(action), style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            const Divider(),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: conflicts.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, index) {
                  final conflict = conflicts[index];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conflict.name,
                        style: const TextStyle(
                          fontFamily: OmniFonts.mono,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _detail(conflict),
                        key: ValueKey('sftp.conflict.${conflict.name}.detail'),
                        style: const TextStyle(fontSize: 11, color: OmniColors.textMuted),
                      ),
                      const SizedBox(height: 4),
                      SegmentedButton<ConflictAction>(
                        key: ValueKey('sftp.conflict.${conflict.name}.action'),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: [
                          for (final action in ConflictAction.values)
                            ButtonSegment(
                              value: action,
                              label: Text(
                                _actionLabel(action),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                        ],
                        selected: {conflict.action},
                        onSelectionChanged: (selection) => setState(
                          () => widget.vm.setPasteConflictAction(conflict.name, selection.first),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('sftp.conflict.cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('sftp.conflict.confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Asks for a single name.
///
/// A widget rather than an inline `TextField`, because the controller must live and die with the
/// dialog: disposing it as soon as `showDialog` returns leaves the still-running exit animation
/// rebuilding a `TextField` around a disposed controller, which throws.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.dialogKey,
    this.initial = '',
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final String dialogKey;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: ValueKey('${widget.dialogKey}.dialog'),
      title: Text(widget.title),
      content: TextField(
        key: ValueKey('${widget.dialogKey}.name'),
        controller: _controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(context).pop(value),
        decoration: omniInputDecoration(context, hintText: widget.hint),
      ),
      actions: [
        TextButton(
          key: ValueKey('${widget.dialogKey}.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ValueKey('${widget.dialogKey}.confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

Future<void> _promptNewFolder(BuildContext context, SftpViewModel vm) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => const _NameDialog(
      title: 'New folder',
      hint: 'Folder name',
      confirmLabel: 'Create',
      dialogKey: 'sftp.newFolder',
    ),
  );
  if (name == null) return;

  final failure = await vm.createDirectory(name);
  // The view model validates, so an invalid name never reaches the server; report it here.
  if (failure != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure)));
  }
}

Future<void> _confirmDelete(BuildContext context, SftpViewModel vm, List<SftpFile> entries) async {
  if (entries.isEmpty) return;
  final directories = entries.where((e) => e.isDirectory).length;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('sftp.delete.dialog'),
      title: Text('Delete ${entries.length} item${entries.length == 1 ? '' : 's'}?'),
      content: Text(
        // A directory delete takes everything under it, which is the part users misjudge.
        directories > 0
            ? 'This includes $directories folder${directories == 1 ? '' : 's'} and everything '
                  'inside ${directories == 1 ? 'it' : 'them'}. Deleted files cannot be recovered.'
            : 'Deleted files cannot be recovered.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('sftp.delete.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('sftp.delete.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.deleteEntries(entries);
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.vm, required this.entry});

  final SftpViewModel vm;
  final SftpFile entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = vm.selectedNames.contains(entry.name);

    return OmniCard(
      key: ValueKey('sftp.entry.${entry.name}'),
      // Tap opens; long-press selects. Tapping used to toggle selection, which made it identical
      // to long-press and left no gesture that *opened* anything — so a file could be browsed to
      // and never looked at. Once a selection exists, tap joins it, because that is what every
      // other multi-select list does.
      onTap: () => entry.isDirectory
          ? vm.open(entry)
          : vm.hasSelection
          ? vm.toggleSelected(entry.name)
          // An image goes to the viewer, not the text editor. The editor would decode the bytes as
          // UTF-8 and offer to save them back, which is the one action guaranteed to corrupt it.
          : isImageFile(entry.name)
          ? vm.openImagePreview(entry)
          : openFileEditor(context, vm, entry),
      onLongPress: () => vm.toggleSelected(entry.name),
      child: Row(
        children: [
          if (vm.hasSelection)
            Checkbox(
              key: ValueKey('sftp.entry.${entry.name}.check'),
              value: selected,
              onChanged: (_) => vm.toggleSelected(entry.name),
            ),
          Icon(
            entry.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined,
            size: 18,
            color: entry.isDirectory ? OmniColors.cyan : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                ),
                Text(
                  [
                    // A directory's size is its inode's, not its contents' — showing it would be a
                    // number that means nothing.
                    if (!entry.isDirectory) formatBytes(entry.size),
                    if (entry.modDate.isNotEmpty) entry.modDate,
                  ].join(' · '),
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            key: ValueKey('sftp.entry.${entry.name}.menu'),
            // Every item below mutates or transfers, so the whole menu closes while one is running,
            // matching the per-item `!shareOpRunning` gates in Compose (ui/SftpScreen.kt:1118-1139).
            enabled: !vm.loading,
            onSelected: (action) => _handle(context, action),
            itemBuilder: (_) => [
              // Only for a directory, and only where there is a shell to run `du` on: a file
              // already shows its real size, and a network share has nothing to ask.
              if (entry.isDirectory && vm.canMeasureSize)
                const PopupMenuItem(value: 'size', child: Text('Measure size')),
              if (!entry.isDirectory && vm.canArchive && SftpViewModel.isArchiveFile(entry.name))
                const PopupMenuItem(value: 'extract', child: Text('Extract here')),
              if (vm.canArchive)
                const PopupMenuItem(value: 'compress', child: Text('Compress to tar.gz')),
              if (!entry.isDirectory)
                const PopupMenuItem(value: 'download', child: Text('Download to device')),
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handle(BuildContext context, String action) async {
    switch (action) {
      case 'size':
        await _measureSize(context, vm, entry);
      case 'extract':
        await _extractArchive(context, vm, entry);
      case 'compress':
        await _createArchive(context, vm, 'tar.gz', only: entry);
      case 'download':
        await _downloadToDevice(context, vm, entry);
      case 'rename':
        await _promptRename(context, vm, entry);
      case 'delete':
        await _confirmDelete(context, vm, [entry]);
    }
  }
}

/// Picks a file on the device and uploads it into the current folder.
///
/// Ported from Kotlin's upload action. `SftpViewModel.upload` existed with no caller, so there was
/// no way to put a file onto a host from this screen at all.
///
/// A clashing name is de-duplicated by [SftpViewModel.upload] rather than overwriting: an upload
/// that silently replaces a file the user did not mean to touch is unrecoverable.
Future<void> _uploadFromDevice(
  BuildContext context,
  SftpViewModel vm, {
  DeviceFileStore store = const DeviceFileStore(),
}) async {
  final picked = await store.pick();
  if (picked == null || !context.mounted) return;

  final size = await vm.sizeOfLocalFile(picked);
  if (!context.mounted) return;
  if (size >= vm.largeTransferBytesThreshold) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.largeUpload.dialog'),
        title: const Text('Large upload batch'),
        content: Text(
          'That file is ${humanBytes(size)}. This meets your configured large-transfer '
          'warning threshold. For very large batches, smaller groups are easier to retry.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('sftp.largeUpload.cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('sftp.largeUpload.confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  await vm.uploadFromDevice(picked);
}

/// Downloads a single file to the device.
///
/// Warned about above the configured threshold, as Kotlin does: a large download over a phone link
/// is worth a second thought, and the setting exists precisely to say where that line is.
Future<void> _downloadToDevice(
  BuildContext context,
  SftpViewModel vm,
  SftpFile entry, {
  DeviceFileStore store = const DeviceFileStore(),
}) async {
  if (entry.size >= vm.largeTransferBytesThreshold) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.largeDownload.dialog'),
        title: const Text('Large download selection'),
        content: Text(
          '"${entry.name}" is ${humanBytes(entry.size)}. This meets your configured '
          'large-transfer warning threshold. For reliability on slow links, consider '
          'smaller batches.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('sftp.largeDownload.cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('sftp.largeDownload.confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  await vm.downloadToDevice(entry, store);
}

Future<void> _downloadSelected(
  BuildContext context,
  SftpViewModel vm, {
  DeviceFileStore store = const DeviceFileStore(),
}) async {
  if (vm.batchDownloadNeedsWarning) {
    final files = vm.selectedFilesForDownload;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.largeBatchDownload.dialog'),
        title: const Text('Large download selection'),
        content: Text(
          '${files.length} file(s), ${humanBytes(vm.selectedDownloadBytes)}. This meets your '
          'configured large-transfer warning threshold. They are fetched one at a time, so a '
          'failure part-way leaves the files already saved in place.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('sftp.largeBatchDownload.cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('sftp.largeBatchDownload.confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  await vm.downloadSelectedToFolder(store);
}

Future<void> _createArchive(
  BuildContext context,
  SftpViewModel vm,
  String format, {
  SftpFile? only,
}) async {
  final target = vm.plannedArchiveName(format, only: only);
  if (target != null && vm.visibleEntries.any((entry) => entry.name == target)) {
    final replace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('sftp.archive.replaceDialog'),
        title: Text('Replace "$target"?'),
        content: const Text(
          'A file with that name already exists and will be overwritten. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('sftp.archive.replace'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Replace', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (replace != true) return;
  }
  await vm.createArchive(format, only: only);
}

Future<void> _extractArchive(BuildContext context, SftpViewModel vm, SftpFile entry) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('sftp.extract.dialog'),
      title: const Text('Extract here?'),
      content: Text(
        'Unpacks "${entry.name}" into this folder. Existing files with the same names will be '
        'overwritten. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('sftp.extract.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Extract'),
        ),
      ],
    ),
  );
  if (confirmed == true) await vm.extractArchive(entry);
}

Future<void> _promptRename(BuildContext context, SftpViewModel vm, SftpFile entry) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(
      title: 'Rename ${entry.name}',
      hint: 'New name',
      confirmLabel: 'Rename',
      dialogKey: 'sftp.rename',
      initial: entry.name,
    ),
  );
  if (name == null) return;

  final failure = await vm.rename(entry, name);
  if (failure != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure)));
  }
}

/// The transfer activity log.
class SftpTransfersTab extends StatelessWidget {
  const SftpTransfersTab({super.key, required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.transfers.isEmpty) {
      return Center(
        key: const ValueKey('sftp.transfers.empty'),
        child: Text(
          'No transfers yet',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      );
    }

    final aggregate = vm.transferAggregate();
    return Column(
      children: [
        if (aggregate != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TransferAggregateBar(aggregate: aggregate),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: vm.activeTransferCount > 0
              ? TextButton.icon(
                  key: const ValueKey('sftp.transfers.cancelAll'),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Cancel all', style: TextStyle(fontSize: 12)),
                  onPressed: vm.cancelAllTransfers,
                )
              : TextButton.icon(
                  key: const ValueKey('sftp.transfers.clear'),
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Clear finished', style: TextStyle(fontSize: 12)),
                  onPressed: vm.clearFinishedTransfers,
                ),
        ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('sftp.transfers.list'),
            itemCount: vm.transfers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final transfer = vm.transfers[index];
              final (color, label) = switch (transfer.status) {
                TransferStatus.running => (OmniColors.cyan, 'RUNNING'),
                TransferStatus.done => (OmniColors.green, 'DONE'),
                TransferStatus.failed => (OmniColors.red, 'FAILED'),
                TransferStatus.cancelled => (OmniColors.amber, 'CANCELLED'),
              };
              return OmniCard(
                key: ValueKey('sftp.transfer.${transfer.id}'),
                leftAccent: color,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          transfer.direction == TransferDirection.download
                              ? Icons.download
                              : Icons.upload,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            transfer.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                          ),
                        ),
                        OmniTag(label: label, color: color),
                        if (transfer.status == TransferStatus.running)
                          IconButton(
                            key: ValueKey('sftp.transfer.${transfer.id}.cancel'),
                            tooltip: 'Cancel transfer',
                            onPressed: () => vm.cancelTransfer(transfer.id),
                            icon: const Icon(Icons.close, size: 16, color: OmniColors.amber),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (transfer.canRetry)
                          IconButton(
                            key: ValueKey('sftp.transfer.${transfer.id}.retry'),
                            tooltip: 'Retry upload',
                            onPressed: () => vm.retryUpload(transfer.id),
                            icon: const Icon(Icons.refresh, size: 16, color: OmniColors.cyan),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    if (transfer.status == TransferStatus.running) ...[
                      const SizedBox(height: 6),
                      // A null value renders an indeterminate bar — honest when the size is
                      // unknown, rather than a made-up fraction.
                      LinearProgressIndicator(value: transfer.progress, minHeight: 3),
                    ],
                    if (transfer.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          transfer.error!,
                          style: const TextStyle(fontSize: 11, color: OmniColors.red),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Measures a directory and shows the result.
///
/// A dialog rather than a value written into the row: `du` walks the whole tree, so the number is a
/// point-in-time answer to a question that was asked, not a property of the listing. Putting it in
/// the row would imply the browser keeps it current.
Future<void> _measureSize(BuildContext context, SftpViewModel vm, SftpFile entry) async {
  final size = await vm.folderSize(entry);
  if (!context.mounted) return;
  // A failure has already put its reason on the screen; a second dialog saying nothing useful over
  // the top of it would only hide the explanation.
  if (size == null) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('sftp.size.dialog'),
      // A size line plus, when `du` could not read everything, a three-line caveat. Nothing here
      // scrolls, so on a small phone at 200% text the caveat is what gets clipped — the one part
      // that says the number is wrong.
      scrollable: true,
      title: Text(entry.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${size.size} on disk',
            key: const ValueKey('sftp.size.value'),
            style: const TextStyle(fontFamily: OmniFonts.mono),
          ),
          if (!size.complete)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                // Observed against a real host: `du` on a directory the login cannot fully read
                // prints a warning *and* a partial total. Presenting that total as the answer would
                // be a confident wrong number about something far larger.
                'At least that much — some directories could not be read, so the real total is '
                'higher.',
                key: ValueKey('sftp.size.partial'),
                style: TextStyle(fontSize: 12, color: OmniColors.amber),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('sftp.size.close'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// What a host-wide search found.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hits = vm.searchHits!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                hits.isEmpty ? 'Nothing found on this host' : '${hits.length} found',
                key: const ValueKey('sftp.search.summary'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            TextButton(
              key: const ValueKey('sftp.search.clear'),
              onPressed: vm.clearSearchHits,
              child: const Text('Back to folder', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Text(
          // Always true and worth saying: a search runs as the logged-in user, so anything that
          // user cannot read is not in these results and never will be.
          vm.searchTruncated
              ? 'Showing the first $remoteSearchMaxHits — narrow the search to see the rest. '
                    'Only what this login can read is searched.'
              : 'Only what this login can read is searched.',
          key: const ValueKey('sftp.search.note'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('sftp.search.list'),
            itemCount: hits.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final hit = hits[index];
              return OmniCard(
                key: ValueKey('sftp.search.hit.$index'),
                leftAccent: hit.isDirectory ? OmniColors.cyan : OmniColors.purple,
                onTap: () => vm.openSearchHit(hit),
                child: Row(
                  children: [
                    Icon(
                      hit.isDirectory ? Icons.folder : Icons.insert_drive_file,
                      size: 16,
                      color: hit.isDirectory ? OmniColors.cyan : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hit.path,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Asks before turning sudo on, and says exactly how far it reaches.
Future<void> _confirmSudo(BuildContext context, SftpViewModel vm) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('sftp.sudo.dialog'),
      title: const Text('Enable sudo mode?'),
      content: const Text(
        // States what actually happens. The previous wording said browsing, renaming and deleting
        // were "unchanged and still run as you", which was false: with sudo on, `mkdir`, `mv` and
        // `rm -rf` all run as root. Telling someone their deletes are unprivileged and then deleting
        // as root is the worst possible direction for that sentence to be wrong in.
        'All file operations on this host will run as root — creating, renaming, deleting, editing '
        'and archiving, as well as opening files this login cannot read.\n\n'
        'This uses the sudo password saved for this host. Turning it off again needs no '
        'authentication.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('sftp.sudo.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('sftp.sudo.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Authenticate', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (!(confirmed ?? false) || !context.mounted) return;

  // Confirming says "I meant to"; this asks "are you the person who saved that sudo password".
  // Kotlin requires the same before switching sudo on (`ui/SftpScreen.kt:1969`), and it is the same
  // gate reboot and service actions use (defect 23).
  final server = vm.browsedServer;
  final lock = context.read<AppLockController>();
  if (server != null && lock.requiresSudoAuth(server.sudoPassword)) {
    if (!await requestSudoAuth(context, lock)) return;
  }
  vm.sudoMode = true;
}
