import 'package:flutter/material.dart';

import '../../../data/remote_commands.dart';
import '../../../data/remote_models.dart';
import '../../../domain/sftp_sort.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/sftp_view_model.dart';
import '../../widgets/omni_components.dart';
import 'file_editor_sheet.dart';

/// Saved paths for the current host.
class SftpBookmarksTab extends StatelessWidget {
  const SftpBookmarksTab({super.key, required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (vm.browsedServer == null) {
      return Center(
        key: const ValueKey('sftp.bookmarks.noHost'),
        child: Text(
          'Bookmarks are saved per host — connect one first.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      );
    }

    return ListView.separated(
      key: const ValueKey('sftp.bookmarks.list'),
      itemCount: vm.bookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = vm.bookmarks[index];
        return OmniCard(
          key: ValueKey('sftp.bookmark.$bookmark'),
          onTap: () => vm.openBookmark(bookmark),
          child: Row(
            children: [
              const Icon(Icons.bookmark, size: 16, color: OmniColors.amber),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  bookmark,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                ),
              ),
              IconButton(
                key: ValueKey('sftp.bookmark.$bookmark.remove'),
                tooltip: 'Remove bookmark',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => vm.toggleBookmark(bookmark),
              ),
            ],
          ),
        );
      },
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Breadcrumbs(vm: vm),
        _Toolbar(vm: vm),
        if (vm.loading) const LinearProgressIndicator(minHeight: 2),
        if (vm.status != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OmniCard(
              key: const ValueKey('sftp.status'),
              leftAccent: OmniColors.green,
              child: Row(
                children: [
                  Expanded(child: Text(vm.status!, style: const TextStyle(fontSize: 12))),
                  IconButton(
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
        const SizedBox(height: 6),
        // Search results take the listing's place while they exist, because they answer a different
        // question than "what is in this folder" and mixing the two would make neither readable.
        if (vm.searchHits != null) Expanded(child: _SearchResults(vm: vm)),
        if (vm.searchHits == null)
          Expanded(
            child: vm.visibleEntries.isEmpty
                ? Center(
                    key: const ValueKey('sftp.empty'),
                    child: Text(
                      // "Nothing matched" and "nothing here" are different facts.
                      vm.searchText.trim().isNotEmpty
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
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.vm});

  final SftpViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trail = vm.breadcrumbTrail;
    if (trail.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 32,
      child: Row(
        children: [
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
    return Row(
      children: [
        Expanded(
          child: SizedBox(
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
          ),
        ),
        // The escalation from the filter beside it: when what you want is not in this folder, the
        // next question is "is it on this host at all".
        if (vm.canSearchHost)
          IconButton(
            key: const ValueKey('sftp.searchHost'),
            tooltip: 'Search this host',
            icon: const Icon(Icons.travel_explore, size: 18, color: OmniColors.cyan),
            onPressed: vm.isSearching || _search.text.trim().isEmpty
                ? null
                : () => vm.searchHost(_search.text),
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
        if (vm.hasSelection)
          IconButton(
            key: const ValueKey('sftp.deleteSelected'),
            tooltip: 'Delete selected',
            icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
            onPressed: () => _confirmDelete(context, vm, vm.selectedEntries),
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
            onSelected: (action) => _handle(context, action),
            itemBuilder: (_) => [
              // Only for a directory, and only where there is a shell to run `du` on: a file
              // already shows its real size, and a network share has nothing to ask.
              if (entry.isDirectory && vm.canMeasureSize)
                const PopupMenuItem(value: 'size', child: Text('Measure size')),
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
      case 'rename':
        await _promptRename(context, vm, entry);
      case 'delete':
        await _confirmDelete(context, vm, [entry]);
    }
  }
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

    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
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
      title: const Text('Read and write as root?'),
      content: const Text(
        // Naming the boundary, because a vaguer "enable sudo" would leave people assuming the
        // browser now deletes as root too.
        'Opening and saving files will use sudo, so you can edit configuration this login cannot '
        'write. Browsing, renaming and deleting are unchanged and still run as you.\n\n'
        'This uses the sudo password saved for this host.',
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
          child: const Text('Use sudo', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) vm.sudoMode = true;
}
