import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/shares/remote_fs_client.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/file_edit.dart';
import '../../domain/remote_path.dart';
import '../../domain/server_credentials.dart';
import '../../domain/sftp_sort.dart';
import 'app_state.dart';

/// The SFTP screen's four sub-tabs, in the Kotlin's order (`ui/SftpScreen.kt` line 113).
///
/// Bookmarks leads because it is the jump list; the two browsing surfaces follow; the transfer log
/// is last.
enum SftpTab { bookmarks, files, shares, transfers }

enum TransferDirection { download, upload }

enum TransferStatus { running, done, failed }

/// One file transfer, kept after it finishes so the user can see what happened.
class SftpTransfer {
  SftpTransfer({
    required this.id,
    required this.name,
    required this.direction,
    required this.totalBytes,
  });

  final String id;
  final String name;
  final TransferDirection direction;
  final int totalBytes;

  int copiedBytes = 0;
  TransferStatus status = TransferStatus.running;
  String? error;

  /// 0..1, or null when the size is unknown — a determinate bar showing a made-up fraction is
  /// worse than an indeterminate one.
  double? get progress => totalBytes > 0 ? (copiedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// The SFTP screen's state and actions, split out of `ui/AppViewModel.kt` per §5.2.
class SftpViewModel extends ChangeNotifier {
  SftpViewModel(this._app, {this.fsClientFor, this.shareClientFor, this.transport}) {
    _app.addListener(_onAppChanged);
  }

  final AppState _app;

  /// Resolves the file client **for a given host**.
  ///
  /// A resolver rather than a single client because this screen switches hosts: an SFTP client is
  /// bound to one set of credentials, so one shared instance would keep talking to whichever host
  /// happened to be selected when the app started — listing the wrong machine's files under the
  /// right machine's name, and deleting from it too.
  ///
  /// Null in tests and in any build without a transport wired; browsing then reports that it is
  /// unavailable rather than showing an empty directory, which reads as "this host has no files".
  /// Asynchronous because building a client needs the host's decrypted key or profile, which lives
  /// in the repository rather than in memory.
  final Future<RemoteFsClient?> Function(Server server)? fsClientFor;

  /// Resolves the file client for a saved **share**.
  ///
  /// Separate from [fsClientFor] because a share carries its own address and credentials and is not
  /// tied to a host at all — but everything downstream (listing, sorting, rename, delete,
  /// transfers) is identical, which is why the browser is generalised here rather than duplicated
  /// into a second screen (§11).
  final Future<RemoteFsClient?> Function(NetworkShare share)? shareClientFor;

  /// A shell on the browsed host, used for the few questions SFTP itself cannot answer.
  ///
  /// Nullable (convention 4): without it the menu simply does not offer folder sizes, rather than
  /// offering an action that fails on tap.
  final SshTransport? transport;

  bool get canBrowse => fsClientFor != null;

  /// Why there is no client, in the user's terms.
  ///
  /// "This build cannot browse files" and "this host's credentials could not be resolved" are
  /// different problems with different fixes, and one message for both sends the user looking in
  /// the wrong place.
  String _unavailable(Server? server, String whenUnsupported) {
    final share = _browsedShare;
    if (share != null) {
      return shareClientFor == null
          ? 'Browsing shares is unavailable in this build.'
          : 'Could not open ${share.name}. Check its address and credentials.';
    }
    return canBrowse
        ? 'Could not open a file connection to ${server?.name ?? 'this host'}. '
              'Check its key or credential profile in the host settings.'
        : whenUnsupported;
  }

  /// The share being browsed, or null when browsing a host.
  ///
  /// A share takes over the Files tab while it is open: it has its own address, credentials and
  /// root, and mixing it with the host's path or bookmarks would let a delete land on the wrong
  /// machine entirely.
  NetworkShare? _browsedShare;

  NetworkShare? get browsedShare => _browsedShare;

  /// True when the Files tab has something to show — a host or a share.
  bool get hasBrowseTarget => _browsedShare != null || browsedServer != null;

  /// What the Files tab is currently showing, for the header.
  String get browseLabel => _browsedShare?.name ?? browsedServer?.name ?? '';

  /// Open [share] in the Files tab.
  Future<void> openShare(NetworkShare share) async {
    _browsedShare = share;
    // Paths and bookmarks belong to whatever was open before; carrying either across would point a
    // listing — or a delete — at a directory on a different machine.
    _path = '';
    _entries = const [];
    _bookmarks = const [];
    _error = null;
    _status = null;
    _activeTab = SftpTab.files;
    _safeNotify();
    await openPath('');
  }

  /// Return to browsing hosts.
  Future<void> closeShare() async {
    if (_browsedShare == null) return;
    _browsedShare = null;
    _path = '';
    _entries = const [];
    _error = null;
    _status = null;
    _safeNotify();
    final server = browsedServer;
    if (server == null) return;
    await _loadBookmarks(server.id);
    await openPath('');
  }

  /// The client for whatever is currently being browsed, or null when there is none.
  Future<RemoteFsClient?> get _client async {
    final share = _browsedShare;
    if (share != null) return shareClientFor?.call(share);
    final server = browsedServer;
    final resolve = fsClientFor;
    if (server == null || resolve == null) return null;
    return resolve(server);
  }

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ── which host ──────────────────────────────────────────────────────────────

  /// Same rule as Monitor and Infra: the explicit selection while it is online, else the first
  /// online host. See MIGRATION.md §15.4.
  Server? get browsedServer {
    final online = _app.servers.where((s) => s.status == 'online');
    final selectedId = _app.selectedServerId;
    for (final server in online) {
      if (server.id == selectedId) return server;
    }
    return online.firstOrNull;
  }

  List<Server> get onlineServers => _app.servers.where((s) => s.status == 'online').toList();

  bool get hasNoOnlineHosts => browsedServer == null;

  void selectServer(int? id) => _app.selectedServerId = id;

  int? _lastServerId;

  /// Primes the screen: loads this host's bookmarks and lists its home directory.
  ///
  /// Explicit rather than done in the constructor because the host list may already have been
  /// emitted by [AppState] before this view model subscribed, in which case no change notification
  /// is coming and nothing would ever load.
  Future<void> start() async {
    final server = browsedServer;
    if (server == null) return;
    _lastServerId = server.id;
    await _loadBookmarks(server.id);
    await openPath('');
  }

  void _onAppChanged() {
    final current = browsedServer?.id;
    // A share owns the Files tab while it is open, so a host going offline behind it must not
    // reset the path or reload the host's bookmarks under the share's listing.
    if (_browsedShare != null) {
      _lastServerId = current;
      _safeNotify();
      return;
    }
    if (current != _lastServerId) {
      _lastServerId = current;
      // One host's directory listing is not another's, and a path that exists on one may not exist
      // on the other at all.
      _path = '';
      _entries = const [];
      _selected.clear();
      _error = null;
      _status = null;
      _bookmarks = const [];
      if (current != null) {
        unawaited(_loadBookmarks(current));
        unawaited(openPath(''));
      }
    }
    _safeNotify();
  }

  // ── tabs ────────────────────────────────────────────────────────────────────

  SftpTab _activeTab = SftpTab.bookmarks;

  SftpTab get activeTab => _activeTab;

  set activeTab(SftpTab value) {
    if (_activeTab == value) return;
    // Only the file browser needs a reachable SSH host; the others work regardless.
    if (value == SftpTab.files && !hasBrowseTarget) return;
    _activeTab = value;
    notifyListeners();
  }

  // ── listing ─────────────────────────────────────────────────────────────────

  String _path = '';
  List<SftpFile> _entries = const [];
  bool _loading = false;
  String? _error;
  String? _status;

  /// The directory currently shown. Empty until the first listing resolves the remote home.
  String get path => _path;

  bool get loading => _loading;

  /// A failure that stopped the listing. Distinct from an empty directory.
  String? get error => _error;

  /// Transient confirmation of an action ("Deleted 3 items"), dismissable.
  String? get status => _status;

  void dismissStatus() {
    _status = null;
    notifyListeners();
  }

  SftpSortOption _sortOption = SftpSortOption.nameAsc;

  SftpSortOption get sortOption => _sortOption;

  set sortOption(SftpSortOption value) {
    if (_sortOption == value) return;
    _sortOption = value;
    // Re-sorting is local; refetching to reorder a listing already in hand would be a round trip
    // the user can feel.
    notifyListeners();
  }

  String _searchText = '';

  String get searchText => _searchText;

  set searchText(String value) {
    if (_searchText == value) return;
    _searchText = value;
    notifyListeners();
  }

  bool _showHidden = false;

  /// Whether dotfiles are listed. Off by default, matching every file manager.
  bool get showHidden => _showHidden;

  set showHidden(bool value) {
    if (_showHidden == value) return;
    _showHidden = value;
    notifyListeners();
  }

  /// The rows to render: hidden files filtered, search applied, then sorted.
  List<SftpFile> get visibleEntries {
    final query = _searchText.trim().toLowerCase();
    final filtered = _entries.where((entry) {
      if (!_showHidden && entry.name.startsWith('.')) return false;
      if (query.isEmpty) return true;
      return entry.name.toLowerCase().contains(query);
    }).toList();
    return sortEntries(filtered, _sortOption);
  }

  List<({String name, String path})> get breadcrumbTrail =>
      _path.isEmpty ? const [] : breadcrumbs(_path);

  /// Opens [target], or the remote home when it is empty.
  Future<void> openPath(String target) async {
    final share = _browsedShare;
    final server = browsedServer;
    // A share is a browse target in its own right; requiring a host here left the share's first
    // listing never issued at all.
    if (share == null && server == null) return;

    final client = await _client;
    if (client == null) {
      _error = _unavailable(server, 'File browsing is unavailable in this build.');
      _safeNotify();
      return;
    }

    _loading = true;
    _error = null;
    _safeNotify();

    // What the listing belongs to. A share's identity is its own; a host's is the host id, which is
    // what changes underneath when the user switches machines mid-fetch.
    final startedFor = share != null ? 'share:${share.id}' : 'host:${server!.id}';
    String currentTarget() =>
        _browsedShare != null ? 'share:${_browsedShare!.id}' : 'host:${browsedServer?.id}';

    try {
      final resolved = target.isEmpty ? await client.home() : normalisePath(target);
      final listing = await client.list(resolved);
      // A listing that lands after the user switched target describes a different machine.
      if (currentTarget() != startedFor) return;
      _path = resolved;
      _entries = listing;
      _selected.clear();
    } catch (e) {
      if (currentTarget() == startedFor) {
        _error = e.toString();
        // The previous directory's rows are not this directory's contents; leaving them visible
        // under a path that failed to open invites acting on the wrong files.
        _entries = const [];
      }
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  Future<void> refresh() => openPath(_path);

  /// Navigates into [entry] when it is a directory.
  Future<void> open(SftpFile entry) async {
    if (!entry.isDirectory) return;
    await openPath(joinPath(_path, entry.name));
  }

  Future<void> goUp() async {
    if (_path.isEmpty || _path == '/') return;
    await openPath(parentPath(_path));
  }

  // ── the text editor ─────────────────────────────────────────────────────────

  /// Whether the current connection can read and write file contents at all.
  ///
  /// A share whose client cannot do this must say so rather than offering an editor that fails on
  /// first tap (convention 4).
  bool get canEditText => _editingClient?.supportsTextEditing ?? false;

  RemoteFsClient? _editingClient;

  /// Reads [entry] for editing, or returns null with [error] set.
  ///
  /// Refuses nothing outright except a file too large to be worth editing on a phone: a binary is
  /// *reported* as one and still opened if the caller insists, because an operator who knows what
  /// a file is should not be argued with (§17).
  Future<String?> readForEditing(SftpFile entry) async {
    final client = await _client;
    _editingClient = client;
    if (client == null) {
      _error = _unavailable(browsedServer, 'File browsing is unavailable in this build.');
      _safeNotify();
      return null;
    }
    if (!client.supportsTextEditing) {
      // Not `_unavailable`: the connection is fine, the *capability* is missing. Blaming the host's
      // credentials for something a share protocol simply cannot do sends the user to fix a setting
      // that was never wrong.
      _error = 'Editing files is not supported on this connection.';
      _safeNotify();
      return null;
    }
    if (!isEditableSize(entry.size)) {
      final mb = (entry.size / (1024 * 1024)).toStringAsFixed(1);
      _error = '"${entry.name}" is $mb MB, too large to open in the editor.';
      _safeNotify();
      return null;
    }

    _loading = true;
    _error = null;
    _safeNotify();
    try {
      return await client.readText(joinPath(_path, entry.name), maxBytes: maxEditableBytes);
    } catch (e) {
      _error = 'Could not open "${entry.name}": $e';
      return null;
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  /// Writes [content] to [entry] and **confirms it landed**.
  ///
  /// The confirmation is the point. A write that returns without throwing is not proof the file was
  /// written — a full disk, a quota, or a path that resolved somewhere else all look like success
  /// from here. The size is read back and compared, and only a match is reported as saved.
  Future<FileSaveResult> saveText(SftpFile entry, String content) async {
    final client = _editingClient ?? await _client;
    if (client == null || !client.supportsTextEditing) {
      return saveFailed('this connection cannot write file contents');
    }

    _loading = true;
    _error = null;
    _safeNotify();
    FileSaveResult result;
    try {
      final expected = utf8.encode(content).length;
      final reported = await client.writeText(joinPath(_path, entry.name), content);
      result = judgeSave(name: entry.name, expected: expected, reported: reported);
    } catch (e) {
      result = saveFailed(e);
    }
    _loading = false;

    // Refreshed either way so the listing's size and date stop describing the old contents — but
    // after the outcome is decided, so a refresh failure cannot masquerade as a save failure.
    await refresh();
    if (result.isError) {
      _error = result.message;
      _status = null;
    } else {
      _status = result.message;
      _error = null;
    }
    _safeNotify();
    return result;
  }

  /// Measures a directory with `du`, returning a human size like `1.2G`.
  ///
  /// Only for a **host**: a network share has no shell to run anything on, which is why the caller
  /// checks [canMeasureSize] rather than this failing halfway.
  ///
  /// A listing shows a directory's index size, not what is inside it — "4.0 KB" for a folder holding
  /// 80 GB is technically right and useless — so this is the answer to the question people open a
  /// file browser to ask.
  bool get canMeasureSize => transport != null && _browsedShare == null && browsedServer != null;

  Future<FolderSize?> folderSize(SftpFile entry) async {
    final ssh = transport;
    final server = browsedServer;
    if (ssh == null || server == null || _browsedShare != null) return null;

    _loading = true;
    _error = null;
    _safeNotify();
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final output = await ssh.exec(creds, folderSizeCommand(joinPath(_path, entry.name)));
      final size = parseFolderSize(output);
      if (size == null) {
        // No number at all: the path is gone, or the host has no `du`. Saying so beats reporting
        // zero, which would read as "this folder is empty".
        _error = 'Could not measure "${entry.name}" — the host refused or has no `du`.';
      }
      return size;
    } on CredentialResolutionException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Could not measure "${entry.name}": $e';
      return null;
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  // ── searching the host ──────────────────────────────────────────────────────

  /// Whether a host-wide search can be run: it needs a shell, which a share does not have.
  bool get canSearchHost => canMeasureSize;

  List<RemoteSearchHit>? _searchHits;
  bool _searchTruncated = false;
  bool _searching = false;

  /// Results of the last host search, or null when none has been run.
  ///
  /// Null and empty mean different things — "not asked" versus "asked, nothing there" — and the
  /// screen says each of them differently.
  List<RemoteSearchHit>? get searchHits =>
      _searchHits == null ? null : List.unmodifiable(_searchHits!);

  bool get searchTruncated => _searchTruncated;
  bool get isSearching => _searching;

  void clearSearchHits() {
    if (_searchHits == null) return;
    _searchHits = null;
    _searchTruncated = false;
    _safeNotify();
  }

  /// Searches the host below the current folder for [query].
  Future<void> searchHost(String query) async {
    final ssh = transport;
    final server = browsedServer;
    if (ssh == null || server == null || _browsedShare != null) return;
    if (query.trim().isEmpty) return;

    _searching = true;
    _searchHits = null;
    _searchTruncated = false;
    _error = null;
    _safeNotify();
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final base = _path.isEmpty ? '/' : _path;
      final output = await ssh.exec(creds, remoteSearchCommand(base, query));
      final result = parseRemoteSearch(output, base: base);
      _searchHits = result.hits;
      _searchTruncated = result.truncated;
    } on CredentialResolutionException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Search failed: $e';
    } finally {
      _searching = false;
      _safeNotify();
    }
  }

  /// Opens the folder a hit lives in, so the result can be acted on with the ordinary browser.
  ///
  /// The browser works on the current directory, so jumping to a *file* means opening its parent —
  /// anything else would show a listing the file is not in.
  Future<void> openSearchHit(RemoteSearchHit hit) async {
    clearSearchHits();
    await openPath(hit.isDirectory ? hit.path : parentPath(hit.path));
  }

  // ── selection ───────────────────────────────────────────────────────────────

  final Set<String> _selected = {};

  Set<String> get selectedNames => Set.unmodifiable(_selected);

  bool get hasSelection => _selected.isNotEmpty;

  void toggleSelected(String name) {
    _selected.contains(name) ? _selected.remove(name) : _selected.add(name);
    notifyListeners();
  }

  void selectAllVisible() {
    _selected
      ..clear()
      ..addAll(visibleEntries.map((e) => e.name));
    notifyListeners();
  }

  void clearSelection() {
    _selected.clear();
    notifyListeners();
  }

  /// The selected rows, resolved against the current listing.
  List<SftpFile> get selectedEntries => _entries.where((e) => _selected.contains(e.name)).toList();

  // ── file operations ─────────────────────────────────────────────────────────

  /// Creates a directory named [name] in the current path.
  ///
  /// Returns the validation failure, or null on success.
  Future<String?> createDirectory(String name) async {
    final valid = validateFileName(name);
    if (valid == null) return 'That name cannot be used.';
    if (_entries.any((e) => e.name == valid)) return '"$valid" already exists here.';
    await _mutate((client) => client.mkdir(joinPath(_path, valid)), success: 'Created $valid');
    return null;
  }

  /// Renames [entry] to [newName].
  Future<String?> rename(SftpFile entry, String newName) async {
    final valid = validateFileName(newName);
    if (valid == null) return 'That name cannot be used.';
    if (valid == entry.name) return null;
    if (_entries.any((e) => e.name == valid)) return '"$valid" already exists here.';
    await _mutate(
      (client) => client.rename(
        joinPath(_path, entry.name),
        joinPath(_path, valid),
        isDirectory: entry.isDirectory,
      ),
      success: 'Renamed to $valid',
    );
    return null;
  }

  /// Deletes [entries]. The caller confirms first — this does not ask.
  Future<void> deleteEntries(List<SftpFile> entries) async {
    if (entries.isEmpty) return;
    await _mutate((client) async {
      for (final entry in entries) {
        await client.delete(joinPath(_path, entry.name), isDirectory: entry.isDirectory);
      }
    }, success: 'Deleted ${entries.length} item${entries.length == 1 ? '' : 's'}');
  }

  /// Runs a mutating operation, then refreshes so the listing reflects what the server actually
  /// did rather than what was requested.
  Future<void> _mutate(
    Future<void> Function(RemoteFsClient client) action, {
    required String success,
  }) async {
    final client = await _client;
    if (client == null) {
      _error = _unavailable(browsedServer, 'File operations are unavailable in this build.');
      _safeNotify();
      return;
    }
    _loading = true;
    _error = null;
    _safeNotify();

    String? failure;
    try {
      await action(client);
    } catch (e) {
      failure = e.toString();
    }
    _loading = false;

    // Refresh first, then report: an operation that partly succeeded must still leave the listing
    // current. Reporting first would let `openPath` clear the error before the user could read it.
    await refresh();
    _error = failure;
    _status = failure == null ? success : null;
    _safeNotify();
  }

  // ── bookmarks ───────────────────────────────────────────────────────────────

  /// Paths worth returning to on the current host.
  ///
  /// Per host rather than global: `/srv/www` is meaningful on one machine and absent on the next, so
  /// a shared list would fill with entries that fail to open.
  List<String> _bookmarks = const [];

  List<String> get bookmarks => List.unmodifiable(_bookmarks);

  /// Seeded on a host with no saved list, so the tab is useful before the user has bookmarked
  /// anything. These are where an administrator actually goes.
  static const defaultBookmarks = ['/root', '/var/log', '/etc', '/opt', '/home'];

  static String _bookmarkKey(int serverId) => 'sftp_bookmarks_$serverId';

  /// The Kotlin's storage format: one settings row per host, paths joined by `|||`.
  static const bookmarkSeparator = '|||';

  Future<void> _loadBookmarks(int serverId) async {
    final raw = await _app.repository.getSetting(_bookmarkKey(serverId));
    _bookmarks = (raw == null || raw.trim().isEmpty)
        ? defaultBookmarks
        : raw.split(bookmarkSeparator).where((s) => s.isNotEmpty).toList();
    _safeNotify();
  }

  bool isBookmarked(String path) => _bookmarks.contains(normalisePath(path));

  /// Bookmarks belong to a host, not to a share: they are stored per `serverId`, and a share has
  /// no host to key them to.
  bool get canBookmark => _browsedShare == null && browsedServer != null;

  Future<void> toggleBookmark(String path) async {
    if (!canBookmark) return;
    final server = browsedServer;
    if (server == null) return;
    final normalised = normalisePath(path);
    _bookmarks = _bookmarks.contains(normalised)
        ? _bookmarks.where((b) => b != normalised).toList()
        : [..._bookmarks, normalised];
    notifyListeners();
    await _app.repository.insertSetting(
      _bookmarkKey(server.id),
      _bookmarks.join(bookmarkSeparator),
    );
  }

  /// Jumps to [bookmark], switching to the browser tab.
  Future<void> openBookmark(String bookmark) async {
    if (browsedServer == null) return;
    _activeTab = SftpTab.files;
    notifyListeners();
    await openPath(bookmark);
  }

  // ── transfers ───────────────────────────────────────────────────────────────

  final List<SftpTransfer> _transfers = [];

  /// Newest first — the one the user just started is the one they want to see.
  List<SftpTransfer> get transfers => List.unmodifiable(_transfers.reversed);

  int get activeTransferCount => _transfers.where((t) => t.status == TransferStatus.running).length;

  void clearFinishedTransfers() {
    _transfers.removeWhere((t) => t.status != TransferStatus.running);
    notifyListeners();
  }

  /// Downloads [entry] into [sink], reporting progress on the Transfers tab.
  ///
  /// The sink is the caller's: choosing where a file lands is a platform concern (a save dialog, a
  /// share sheet), and this class deliberately knows nothing about local storage.
  Future<void> download(SftpFile entry, StreamSink<List<int>> sink) async {
    final client = await _client;
    if (client == null) return;
    final transfer = SftpTransfer(
      id: '${DateTime.now().microsecondsSinceEpoch}-${entry.name}',
      name: entry.name,
      direction: TransferDirection.download,
      totalBytes: entry.size,
    );
    _transfers.add(transfer);
    _safeNotify();

    try {
      await client.downloadTo(
        joinPath(_path, entry.name),
        sink,
        onProgress: (copied, total) {
          transfer.copiedBytes = copied;
          _safeNotify();
        },
      );
      transfer.status = TransferStatus.done;
    } catch (e) {
      transfer
        ..status = TransferStatus.failed
        ..error = e.toString();
    }
    _safeNotify();
  }

  /// Uploads [bytes] into the current directory as [name].
  ///
  /// A clashing name is given a `(2)` suffix rather than overwriting: an upload that silently
  /// replaces a file the user did not mean to touch is unrecoverable.
  Future<void> upload(String name, Stream<List<int>> bytes, int totalBytes) async {
    final client = await _client;
    if (client == null) return;
    final safe = uniqueName(name, _entries.map((e) => e.name).toSet());
    final transfer = SftpTransfer(
      id: '${DateTime.now().microsecondsSinceEpoch}-$safe',
      name: safe,
      direction: TransferDirection.upload,
      totalBytes: totalBytes,
    );
    _transfers.add(transfer);
    _safeNotify();

    try {
      await client.uploadStream(
        joinPath(_path, safe),
        bytes,
        totalBytes,
        onProgress: (copied, total) {
          transfer.copiedBytes = copied;
          _safeNotify();
        },
      );
      transfer.status = TransferStatus.done;
      await refresh();
    } catch (e) {
      transfer
        ..status = TransferStatus.failed
        ..error = e.toString();
      _safeNotify();
    }
  }

  // ── credentials, for whoever opens the connection ───────────────────────────

  /// Resolves the browsed host's credentials, so the caller can build a client for it.
  SshCredentials? credentialsForBrowsedServer({
    required List<SshKey> keys,
    required List<CredentialProfile> profiles,
  }) {
    final server = browsedServer;
    if (server == null) return null;
    try {
      return resolveCredentials(server, keys: keys, profiles: profiles);
    } on CredentialResolutionException catch (e) {
      _error = e.message;
      _safeNotify();
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _app.removeListener(_onAppChanged);
    super.dispose();
  }
}
