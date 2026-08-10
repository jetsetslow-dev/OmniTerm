import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_commands.dart';
import '../../data/remote_models.dart';
import '../../data/remote_parsers.dart';
import '../../data/shares/remote_fs_client.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../domain/endpoint_bookmark.dart';
import '../../domain/file_edit.dart';
import '../../domain/image_preview.dart';
import '../../platform/device_file_store.dart';
import '../../domain/remote_path.dart';
import '../../domain/server_credentials.dart';
import '../../domain/sftp_sort.dart';
import '../../domain/transfer_aggregate.dart';
import 'app_state.dart';

/// The SFTP screen's four sub-tabs, in the Kotlin's order (`ui/SftpScreen.kt` line 113).
///
/// Bookmarks leads because it is the jump list; the two browsing surfaces follow; the transfer log
/// is last.
enum SftpTab { bookmarks, files, shares, transfers }

enum TransferDirection { download, upload }

enum TransferStatus { running, done, failed }

class _ClipboardEndpoint {
  const _ClipboardEndpoint({this.serverId, this.share, required this.label});

  final int? serverId;
  final NetworkShare? share;
  final String label;

  String get key => share != null ? 'share:${share!.id}' : 'host:$serverId';
}

class _RemoteClipboard {
  const _RemoteClipboard({
    required this.endpoint,
    required this.directory,
    required this.entries,
    required this.move,
  });

  final _ClipboardEndpoint endpoint;
  final String directory;
  final List<SftpFile> entries;
  final bool move;
}

/// One file transfer, kept after it finishes so the user can see what happened.
class SftpTransfer {
  SftpTransfer({
    required this.id,
    required this.name,
    required this.direction,
    required this.totalBytes,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String id;
  final String name;
  final TransferDirection direction;
  final int totalBytes;

  /// When the transfer began, so a rate can be derived. Injectable for tests, which cannot wait a
  /// real second to observe a speed.
  final DateTime startedAt;

  int copiedBytes = 0;
  TransferStatus status = TransferStatus.running;
  String? error;

  /// 0..1, or null when the size is unknown — a determinate bar showing a made-up fraction is
  /// worse than an indeterminate one.
  double? get progress => totalBytes > 0 ? (copiedBytes / totalBytes).clamp(0.0, 1.0) : null;

  /// Average rate since the transfer started, in KB/s.
  ///
  /// Averaged rather than sampled between updates: a per-chunk rate on a mobile link swings so
  /// wildly that the ETA built on it is unreadable. Kotlin averages the same way
  /// (`ui/AppViewModel.kt:9898`).
  double speedKbps({DateTime? now}) {
    final elapsed = (now ?? DateTime.now()).difference(startedAt).inMilliseconds;
    if (elapsed <= 0 || copiedBytes <= 0) return 0;
    return copiedBytes / (elapsed / 1000) / 1024;
  }
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
    // The share's own bookmarks, not the host's: `/etc` on the machine you were browsing is not a
    // path on this share, and starring one there must not fill in the other.
    await _loadBookmarksFrom(bookmarkStorageKey(shareId: share.id)!, seedDefaults: false);
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
    // Restored before the first listing, so the initial view is already in the user's order rather
    // than snapping from Name A-Z to their choice a moment later.
    await _restoreSortOption();
    await _restoreRecurseFolders();
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
    // Persisted like Kotlin's `sftp_sort` (`AppViewModel.kt:1410`): a browser that forgets how the
    // user asked to see their files every time the app restarts is a setting that does not exist.
    // Fire-and-forget, matching Kotlin's `viewModelScope.launch` — the sort is already applied, and
    // the write must not make the list wait.
    unawaited(_app.repository.insertSetting('sftp_sort', value.name));
    // Re-sorting is local; refetching to reorder a listing already in hand would be a round trip
    // the user can feel.
    notifyListeners();
  }

  /// Whether the user has opted into copying folder contents recursively.
  ///
  /// Persisted under Kotlin's `cross_paste_recurse` key, which exists because the choice is a
  /// standing preference rather than a per-paste decision: Kotlin offers it as a checkbox in the
  /// clipboard bar and remembers it. Flutter has no clipboard bar to put a checkbox in, so the
  /// prompt stays — but once answered yes it is not asked again, which is the part that was missing.
  bool get recurseFolders => _recurseFolders;
  bool _recurseFolders = false;

  Future<void> setRecurseFolders(bool value) async {
    if (_recurseFolders == value) return;
    _recurseFolders = value;
    await _app.repository.insertSetting('cross_paste_recurse', '$value');
    _safeNotify();
  }

  Future<void> _restoreRecurseFolders() async {
    final stored = await _app.repository.getSetting('cross_paste_recurse');
    final value = stored?.trim().toLowerCase() == 'true';
    if (_disposed || value == _recurseFolders) return;
    _recurseFolders = value;
    _safeNotify();
  }

  /// Reads the stored sort order back.
  Future<void> _restoreSortOption() async {
    final stored = await _app.repository.getSetting('sftp_sort');
    final option = SftpSortOption.fromStored(stored);
    if (_disposed || option == _sortOption) return;
    _sortOption = option;
    _safeNotify();
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
  /// Why the file now open in the editor is not safe to save, or null.
  ///
  /// Set by [readForEditing]. A warning rather than a refusal: the file is still shown, because an
  /// operator who knows what they are looking at may well want to read it.
  String? get editorBinaryWarning => _editorBinaryWarning;
  String? _editorBinaryWarning;

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
      final path = joinPath(_path, entry.name);
      final content = _sudo && transport != null && browsedServer != null
          ? await _sudoRead(path)
          : await client.readText(path, maxBytes: maxEditableBytes);
      // Checked on the way out rather than at the call site so every route into the editor — sudo
      // read included — is covered by the same warning.
      _editorBinaryWarning = content == null ? null : binaryEditWarning(content);
      return content;
    } catch (e) {
      _error = 'Could not open "${entry.name}": $e';
      return null;
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  /// Reads a protected file over an exec channel, because SFTP cannot elevate.
  Future<String?> _sudoRead(String path) async {
    final server = browsedServer!;
    final creds = resolveCredentials(
      server,
      keys: await _app.repository.getAllKeys(),
      profiles: await _app.repository.getAllProfiles(),
    );
    final output = await transport!.exec(
      creds,
      sudoReadCommand(path, server.sudoPassword),
      stdin: sudoStdin(server.sudoPassword),
    );
    final contents = parseSudoRead(output);
    if (contents == null) {
      // No marker means the command never ran, so the output *is* the reason — a wrong sudo
      // password, no sudo rights, a missing file. Showing it beats inventing a summary.
      _error = 'Could not read "$path" as root: ${output.trim()}';
    }
    return contents;
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
      final dest = joinPath(_path, entry.name);
      final reported = _sudo && transport != null && browsedServer != null
          ? await _sudoWrite(client, dest, content)
          : await client.writeText(dest, content);
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

  // ── sudo ────────────────────────────────────────────────────────────────────

  bool _sudo = false;

  /// Whether host file operations are run as root where SFTP itself cannot elevate.
  ///
  /// Listing remains an ordinary SFTP listing; create, rename, delete, editing and archive actions
  /// use a separately authenticated sudo exec path. Every destructive action keeps its normal
  /// confirmation even while elevated.
  bool get sudoMode => _sudo;

  /// True when sudo can be offered at all: it needs a shell, and a host rather than a share.
  bool get canUseSudo => canMeasureSize;

  /// True when a save from the editor will actually be written as root.
  ///
  /// The same condition [saveText] applies, exposed so the editor can *say so*. Sudo mode is a
  /// screen-level toggle, and an editor open on `/etc/nginx/nginx.conf` that shows a plain "Save"
  /// gives no sign that the write about to happen is a privileged one.
  bool get sudoWritesApply => _sudo && transport != null && browsedServer != null;

  set sudoMode(bool value) {
    if (_sudo == value) return;
    _sudo = value;
    _safeNotify();
  }

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
  ///
  /// **Runs as root when sudo mode is on**, matching every other exec on this screen and
  /// `runSftpSearch` (`ui/AppViewModel.kt:8962`). Without it, searching a tree the user explicitly
  /// elevated to reach returns nothing: `find` sends its permission errors to `/dev/null`, so an
  /// unprivileged search of `/etc` or `/root` reports "nothing matched" rather than "not permitted"
  /// — a wrong answer wearing the clothes of a right one.
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
      final script = remoteSearchCommand(base, query);
      final output = await ssh.exec(
        creds,
        _sudo ? sudoShWrap(script, server.sudoPassword) : script,
        stdin: _sudo ? sudoStdin(server.sudoPassword) : null,
      );
      // A refused sudo has to be said out loud. `find` sends its own permission errors to
      // /dev/null, so without this the search would report "nothing matched" for a tree it was
      // never allowed to read — the failure mode this whole change exists to remove.
      final refused = _sudo ? searchSudoFailure(output) : null;
      if (refused != null) {
        _error = 'Search failed: $refused';
        return;
      }
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

  /// Writes to a path the login cannot, and reports the size the server ends up with.
  ///
  /// SFTP cannot write there, so the content goes to a temp file the login *can* write and is
  /// copied into place with sudo. The temp copy is removed by the same command whether or not the
  /// copy succeeded: leaving a readable copy of a protected file in `/tmp` would quietly widen
  /// access to it.
  Future<int> _sudoWrite(RemoteFsClient client, String dest, String content) async {
    final server = browsedServer!;
    final temp = sudoTempPath();
    await client.writeText(temp, content);
    final creds = resolveCredentials(
      server,
      keys: await _app.repository.getAllKeys(),
      profiles: await _app.repository.getAllProfiles(),
    );
    final output = await transport!.exec(
      creds,
      sudoWriteCommand(temp, dest, server.sudoPassword),
      stdin: sudoStdin(server.sudoPassword),
    );
    return parseSudoWriteSize(output);
  }

  // ── selection ───────────────────────────────────────────────────────────────

  final Set<String> _selected = {};

  Set<String> get selectedNames => Set.unmodifiable(_selected);

  bool get hasSelection => _selected.isNotEmpty;

  void toggleSelected(String name) {
    _selected.contains(name) ? _selected.remove(name) : _selected.add(name);
    notifyListeners();
  }

  /// Selects every row currently on screen.
  ///
  /// **Visible**, not every entry: with a search term typed or dotfiles hidden, selecting rows the
  /// user cannot see would put files they never chose into the next delete.
  void selectAllVisible() {
    _selected
      ..clear()
      ..addAll(visibleEntries.map((e) => e.name));
    notifyListeners();
  }

  /// True when there is anything to select that is not already selected.
  ///
  /// Drives the button's enabled state, so "select all" in a folder that is already fully selected
  /// is visibly a no-op rather than a button that appears to do nothing.
  bool get canSelectAllVisible => visibleEntries.any((e) => !_selected.contains(e.name));

  void clearSelection() {
    _selected.clear();
    notifyListeners();
  }

  /// The selected rows, resolved against the current listing.
  List<SftpFile> get selectedEntries => _entries.where((e) => _selected.contains(e.name)).toList();

  bool get canArchive => canMeasureSize;

  static bool isArchiveFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.zip') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.tar.bz2') ||
        lower.endsWith('.tbz2') ||
        lower.endsWith('.tar.xz') ||
        lower.endsWith('.txz') ||
        lower.endsWith('.7z') ||
        lower.endsWith('.rar');
  }

  String? plannedArchiveName(String format, {SftpFile? only}) {
    final names = only == null ? selectedEntries.map((entry) => entry.name).toList() : [only.name];
    if (names.length != 1) return null;
    final source = names.single;
    final dot = source.lastIndexOf('.');
    final base = dot > 0 ? source.substring(0, dot) : source;
    final extension = switch (format) {
      'zip' => 'zip',
      'tar' => 'tar',
      '7z' => '7z',
      _ => 'tar.gz',
    };
    return '$base.$extension';
  }

  Future<bool> createArchive(String format, {SftpFile? only}) async {
    final entries = only == null ? selectedEntries : [only];
    if (entries.isEmpty || !canArchive) return false;
    final now = DateTime.now();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final archiveName =
        plannedArchiveName(format, only: only) ??
        'archive-$stamp.${switch (format) {
          'zip' => 'zip',
          'tar' => 'tar',
          '7z' => '7z',
          _ => 'tar.gz',
        }}';
    return _runArchiveCommand(
      archiveCreateCommand(_path.isEmpty ? '.' : _path, archiveName, [
        for (final e in entries) e.name,
      ], format),
      sentinel: 'OMNITERM_ARCHIVE_OK',
      success: 'Created $archiveName${_sudo ? ' as root' : ''}.',
      failurePrefix: 'Archive failed',
      clearSelection: only == null,
    );
  }

  Future<bool> extractArchive(SftpFile entry) async {
    if (!isArchiveFile(entry.name) || !canArchive) return false;
    return _runArchiveCommand(
      archiveExtractCommand(_path.isEmpty ? '.' : _path, entry.name),
      sentinel: 'OMNITERM_EXTRACT_OK',
      success: 'Extracted ${entry.name}${_sudo ? ' as root' : ''}.',
      failurePrefix: 'Extract failed',
    );
  }

  Future<bool> _runArchiveCommand(
    String command, {
    required String sentinel,
    required String success,
    required String failurePrefix,
    bool clearSelection = false,
  }) async {
    final server = browsedServer;
    final ssh = transport;
    if (server == null || ssh == null || _browsedShare != null) return false;
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final output = await ssh.exec(
        creds,
        _sudo ? sudoShWrap(command, server.sudoPassword) : command,
        stdin: _sudo ? sudoStdin(server.sudoPassword) : null,
      );
      if (!output.contains(sentinel)) {
        _error =
            '$failurePrefix: ${output.trim().isEmpty ? 'the host returned no result' : output.trim()}';
        return false;
      }
      if (clearSelection) _selected.clear();
      _status = success;
      await openPath(_path);
      return true;
    } catch (e) {
      _error = '$failurePrefix: $e';
      return false;
    } finally {
      _loading = false;
      _safeNotify();
    }
  }

  _RemoteClipboard? _clipboard;

  bool get hasClipboard => _clipboard != null;
  bool get clipboardContainsFolders =>
      _clipboard?.entries.any((entry) => entry.isDirectory) ?? false;
  String get clipboardSummary {
    final clipboard = _clipboard;
    if (clipboard == null) return '';
    final action = clipboard.move ? 'Move' : 'Copy';
    return '$action ${clipboard.entries.length} item${clipboard.entries.length == 1 ? '' : 's'} from ${clipboard.endpoint.label}';
  }

  /// The byte threshold above which a transfer is worth warning about.
  int get largeTransferBytesThreshold => _app.sftpLargeBatchBytesThreshold;

  bool get selectedTransferNeedsWarning {
    final selected = selectedEntries;
    return selected.length >= _app.sftpLargeBatchFileThreshold ||
        selected.fold<int>(0, (sum, entry) => sum + entry.size) >=
            _app.sftpLargeBatchBytesThreshold;
  }

  _ClipboardEndpoint get _currentEndpoint => _browsedShare != null
      ? _ClipboardEndpoint(share: _browsedShare, label: _browsedShare!.name)
      : _ClipboardEndpoint(serverId: browsedServer?.id, label: browsedServer?.name ?? 'host');

  void stageSelected({required bool move}) {
    final entries = selectedEntries;
    if (entries.isEmpty) return;
    _clipboard = _RemoteClipboard(
      endpoint: _currentEndpoint,
      directory: _path,
      entries: [
        for (final entry in entries)
          SftpFile(
            name: entry.name,
            isDirectory: entry.isDirectory,
            size: entry.size,
            modDate: entry.modDate,
            modTimeSeconds: entry.modTimeSeconds,
          ),
      ],
      move: move,
    );
    _selected.clear();
    _status = clipboardSummary;
    _safeNotify();
  }

  void clearClipboard() {
    if (_clipboard == null) return;
    _clipboard = null;
    _safeNotify();
  }

  Future<RemoteFsClient?> _clientForEndpoint(_ClipboardEndpoint endpoint) async {
    final share = endpoint.share;
    if (share != null) return shareClientFor?.call(share);
    final server = _app.servers.where((server) => server.id == endpoint.serverId).firstOrNull;
    return server == null ? null : fsClientFor?.call(server);
  }

  // ── destination conflicts ───────────────────────────────────────────────────
  //
  // Ported from `sftpBeginPaste` in `ui/AppViewModel.kt`. Pasting used to auto-rename every clash,
  // so a file could never be replaced and the user was never told one existed.

  List<TransferConflict> _pasteConflicts = const [];
  bool _conflictScanRunning = false;
  bool _conflictsUnverified = false;
  _RemoteClipboard? _pendingPaste;
  bool _pendingRecurseFolders = false;

  /// Clashes awaiting the user's decision. Empty means nothing is being asked.
  List<TransferConflict> get pasteConflicts => List.unmodifiable(_pasteConflicts);

  bool get conflictScanRunning => _conflictScanRunning;

  /// True when at least one clash could not be compared by content, so "identical" cannot be
  /// claimed for it. The UI must say so rather than implying the pair matched.
  bool get conflictsUnverified => _conflictsUnverified;

  /// Scans the destination, then pastes straight away or surfaces the clashes for resolution.
  ///
  /// Name collisions come from the listing already on screen, so they are detected for every
  /// endpoint — SSH, SMB, FTP and WebDAV alike. Content verdicts need a shell, so they are added
  /// only when the destination is an SSH host; everywhere else the verdict stays
  /// [ConflictVerdict.unknown], which is honest rather than a guessed match.
  Future<void> beginPaste({required bool recurseFolders}) async {
    final clipboard = _clipboard;
    if (clipboard == null || _conflictScanRunning) return;
    if (clipboardContainsFolders && !recurseFolders) {
      _error = 'This selection contains folders. Enable recursive copy to include them.';
      _safeNotify();
      return;
    }
    final recursive = _selfContainingFolder(clipboard);
    if (recursive != null) {
      _error = 'Cannot paste "$recursive" into itself. Choose a folder outside it.';
      _safeNotify();
      return;
    }

    final existing = _entries.map((entry) => entry.name).toSet();
    final clashing = clipboard.entries.where((entry) => existing.contains(entry.name)).toList();
    if (clashing.isEmpty) {
      await pasteClipboard(recurseFolders: recurseFolders);
      return;
    }

    _conflictScanRunning = true;
    _error = null;
    _safeNotify();
    try {
      final verdicts = await _scanConflicts(clipboard, clashing);
      // The clipboard can be restaged while the scan is in flight; resolving against a selection
      // the user has since replaced would paste the wrong thing.
      if (!identical(_clipboard, clipboard)) {
        _error = 'Paste cancelled: the selection changed while the destination was scanned.';
        return;
      }
      _pasteConflicts = verdicts;
      _conflictsUnverified = verdicts.any((c) => c.verdict == ConflictVerdict.unknown);
      _pendingPaste = clipboard;
      _pendingRecurseFolders = recurseFolders;
    } catch (error) {
      _error = 'Paste cancelled: conflict scan failed: $error';
    } finally {
      _conflictScanRunning = false;
      _safeNotify();
    }
  }

  /// The name of a staged folder that the current directory sits inside, or null.
  ///
  /// Pasting a folder into its own subtree is unbounded: [_copyRemoteEntry] creates the destination
  /// and then lists the source, which now contains what it just created, and recurses into it
  /// forever — filling the remote disk and hanging the transfer. A same-endpoint *move* is safe
  /// because the server refuses the rename, but a copy is the app's own recursion and nothing stops
  /// it. Compared segment-wise by [isWithin], so `/srv/www-old` is correctly seen as a sibling of
  /// `/srv/www` rather than a child.
  String? _selfContainingFolder(_RemoteClipboard clipboard) {
    if (clipboard.endpoint.key != _currentEndpoint.key) return null;
    for (final entry in clipboard.entries) {
      if (!entry.isDirectory) continue;
      if (isWithin(joinPath(clipboard.directory, entry.name), _path)) {
        return entry.name;
      }
    }
    return null;
  }

  /// Classifies [clashing] against the destination.
  Future<List<TransferConflict>> _scanConflicts(
    _RemoteClipboard clipboard,
    List<SftpFile> clashing,
  ) async {
    final server = browsedServer;
    final ssh = transport;
    final sameEndpoint = clipboard.endpoint.key == _currentEndpoint.key;
    final destination = _path.isEmpty ? '/' : _path;

    List<TransferConflict> conflicts;
    // The scan runs one shell command on the destination host, so it can only compare sources that
    // live on that same host.
    if (_browsedShare == null && server != null && ssh != null && sameEndpoint) {
      final sources = [for (final entry in clashing) joinPath(clipboard.directory, entry.name)];
      final script = compareForConflicts(destination, sources);
      final credentials = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final output = _sudo
          ? await ssh.exec(
              credentials,
              sudoShWrap(script, server.sudoPassword),
              stdin: sudoStdin(server.sudoPassword),
            )
          : await ssh.exec(credentials, script);

      // A scan that died part way must never read as "no conflicts" — that would turn a failed
      // check into a silent overwrite.
      if (!output.contains(conflictScanOk)) {
        throw StateError('the destination conflict scan did not complete');
      }
      final body = output.split('\n').where((line) => line.trim() != conflictScanOk).join('\n');
      conflicts = parseTransferConflicts(body, sources);
    } else {
      conflicts = const [];
    }

    // Anything the scan could not classify — including every clash on a share, where no shell
    // exists — is still shown, as unverified.
    final classified = {for (final conflict in conflicts) conflict.name: conflict};
    return [
      for (final entry in clashing)
        _adjustForSameFolder(
          classified[entry.name] ??
              TransferConflict(
                name: entry.name,
                verdict: ConflictVerdict.unknown,
                sourceSize: entry.size,
                destSize: _entries.where((e) => e.name == entry.name).firstOrNull?.size ?? 0,
                sourceMtimeSeconds: entry.modTimeSeconds,
                destMtimeSeconds: 0,
              ),
          clipboard,
        ),
    ];
  }

  /// Pasting into the folder the items came from is a special case.
  ///
  /// Copying there should produce "name (2)"; moving there is a no-op. Leaving an IDENTICAL default
  /// of overwrite would instead delete the file and then copy it onto itself.
  TransferConflict _adjustForSameFolder(TransferConflict conflict, _RemoteClipboard clipboard) {
    final sourceDir = normalisePath(clipboard.directory);
    final destDir = normalisePath(_path);
    if (clipboard.endpoint.key != _currentEndpoint.key || sourceDir != destDir) {
      return conflict;
    }
    return conflict.copyWith(
      action: clipboard.move ? ConflictAction.skip : ConflictAction.keepBoth,
    );
  }

  void setPasteConflictAction(String name, ConflictAction action) {
    _pasteConflicts = [
      for (final conflict in _pasteConflicts)
        conflict.name == name ? conflict.copyWith(action: action) : conflict,
    ];
    _safeNotify();
  }

  void setAllPasteConflictActions(ConflictAction action) {
    _pasteConflicts = [for (final conflict in _pasteConflicts) conflict.copyWith(action: action)];
    _safeNotify();
  }

  void cancelPasteConflicts() {
    _pasteConflicts = const [];
    _pendingPaste = null;
    _conflictsUnverified = false;
    _safeNotify();
  }

  /// Applies the user's per-item choices and runs the paste.
  Future<void> confirmPasteConflicts() async {
    final pending = _pendingPaste;
    final resolutions = {for (final conflict in _pasteConflicts) conflict.name: conflict.action};
    final recurse = _pendingRecurseFolders;
    _pasteConflicts = const [];
    _pendingPaste = null;
    _conflictsUnverified = false;
    if (pending == null || !identical(_clipboard, pending)) {
      _error = 'Paste cancelled: the selection changed before it was confirmed.';
      _safeNotify();
      return;
    }
    await pasteClipboard(recurseFolders: recurse, resolutions: resolutions);
  }

  /// Seeds the transfer list, for tests that need a batch without running one.
  @visibleForTesting
  void debugAddTransfers(List<SftpTransfer> transfers) {
    _transfers.addAll(transfers);
    _safeNotify();
  }

  /// Overall progress across everything currently transferring, or null when nothing is.
  ///
  /// Ported from `transferAggregate` (`ui/AppViewModel.kt:9874`). The per-file bars answer "is this
  /// file moving?"; this answers "how long until the batch is across", which is the question a user
  /// moving a folder actually has.
  TransferAggregate? transferAggregate({DateTime? now}) => aggregateTransfers([
    for (final t in _transfers)
      if (t.status == TransferStatus.running)
        TransferProgress(
          bytesTransferred: t.copiedBytes,
          totalBytes: t.totalBytes,
          speedKbps: t.speedKbps(now: now),
        ),
  ]);

  /// Copies or moves the staged items into the current folder, including across hosts/protocols.
  ///
  /// [resolutions] decides what happens to a name that already exists at the destination. A name
  /// with no entry defaults to keeping both, which is what this did for everything before the
  /// conflict scan existed.
  Future<void> pasteClipboard({
    required bool recurseFolders,
    Map<String, ConflictAction> resolutions = const {},
  }) async {
    final clipboard = _clipboard;
    if (clipboard == null) return;
    if (clipboardContainsFolders && !recurseFolders) {
      _error = 'This selection contains folders. Enable recursive copy to include them.';
      _safeNotify();
      return;
    }
    // Checked here too, not only in [beginPaste]: this is the method that actually recurses, and it
    // is reachable directly.
    final recursive = _selfContainingFolder(clipboard);
    if (recursive != null) {
      _error = 'Cannot paste "$recursive" into itself. Choose a folder outside it.';
      _safeNotify();
      return;
    }
    final source = await _clientForEndpoint(clipboard.endpoint);
    final destination = await _client;
    if (source == null || destination == null) {
      _error = 'Could not open both the source and destination connections.';
      _safeNotify();
      return;
    }
    _loading = true;
    _error = null;
    _safeNotify();
    final existing = _entries.map((entry) => entry.name).toSet();
    var transferred = 0;
    var skipped = 0;
    try {
      for (final entry in clipboard.entries) {
        final clashes = existing.contains(entry.name);
        final action = clashes
            ? (resolutions[entry.name] ?? ConflictAction.keepBoth)
            : ConflictAction.keepBoth;
        if (clashes && action == ConflictAction.skip) {
          skipped++;
          continue;
        }

        final String destinationName;
        if (clashes && action == ConflictAction.overwrite) {
          // Remove the existing entry first so the replacement lands under the original name.
          // Doing it this way makes overwrite behave identically for a same-endpoint rename and a
          // cross-endpoint stream, and for every protocol behind [RemoteFsClient].
          await destination.delete(joinPath(_path, entry.name), isDirectory: entry.isDirectory);
          existing.remove(entry.name);
          destinationName = entry.name;
        } else {
          destinationName = uniqueName(entry.name, existing);
        }
        existing.add(destinationName);

        final from = joinPath(clipboard.directory, entry.name);
        final to = joinPath(_path, destinationName);
        if (clipboard.move && clipboard.endpoint.key == _currentEndpoint.key) {
          await source.rename(from, to, isDirectory: entry.isDirectory);
        } else {
          await _copyRemoteEntry(source, destination, entry, from, to, move: clipboard.move);
        }
        transferred++;
      }
      final verb = clipboard.move ? 'Moved' : 'Copied';
      _status =
          '$verb $transferred item${transferred == 1 ? '' : 's'}'
          '${skipped > 0 ? ', skipped $skipped' : ''}.';
      _clipboard = null;
    } catch (error) {
      _error = 'Transfer stopped: $error';
    } finally {
      _loading = false;
      await refresh();
      _safeNotify();
    }
  }

  Future<void> _copyRemoteEntry(
    RemoteFsClient source,
    RemoteFsClient destination,
    SftpFile entry,
    String from,
    String to, {
    required bool move,
  }) async {
    if (entry.isDirectory) {
      await destination.mkdir(to);
      for (final child in await source.list(from)) {
        await _copyRemoteEntry(
          source,
          destination,
          child,
          joinPath(from, child.name),
          joinPath(to, child.name),
          move: move,
        );
      }
      if (move) await source.delete(from, isDirectory: true);
      return;
    }

    final transfer = SftpTransfer(
      id: '${DateTime.now().microsecondsSinceEpoch}-${entry.name}',
      name: entry.name,
      direction: TransferDirection.upload,
      totalBytes: entry.size,
    );
    _transfers.add(transfer);
    final tempDirectory = await Directory.systemTemp.createTemp('omniterm-cross-');
    final temp = File('${tempDirectory.path}/payload');
    try {
      final sink = temp.openWrite();
      await source.downloadTo(
        from,
        sink,
        onProgress: (copied, total) {
          transfer.copiedBytes = copied ~/ 2;
          _safeNotify();
        },
      );
      await sink.close();
      final size = await temp.length();
      await destination.uploadStream(
        to,
        temp.openRead(),
        size,
        onProgress: (copied, total) {
          transfer.copiedBytes = (size / 2 + copied / 2).round();
          _safeNotify();
        },
      );
      transfer
        ..copiedBytes = size
        ..status = TransferStatus.done;
      if (move) await source.delete(from, isDirectory: false);
    } catch (error) {
      transfer
        ..status = TransferStatus.failed
        ..error = error.toString();
      rethrow;
    } finally {
      if (await temp.exists()) await temp.delete();
      if (await tempDirectory.exists()) await tempDirectory.delete();
      _safeNotify();
    }
  }

  // ── file operations ─────────────────────────────────────────────────────────

  /// Creates a directory named [name] in the current path.
  ///
  /// Returns the validation failure, or null on success.
  Future<String?> createDirectory(String name) async {
    final valid = validateFileName(name);
    if (valid == null) return 'That name cannot be used.';
    if (_entries.any((e) => e.name == valid)) {
      return '"$valid" already exists here.';
    }
    final destination = joinPath(_path, valid);
    if (_sudo && browsedServer != null && _browsedShare == null) {
      await _sudoMutation('mkdir -- ${shellQuote(destination)}', success: 'Created $valid (sudo)');
    } else {
      await _mutate((client) => client.mkdir(destination), success: 'Created $valid');
    }
    return null;
  }

  /// Renames [entry] to [newName].
  Future<String?> rename(SftpFile entry, String newName) async {
    final valid = validateFileName(newName);
    if (valid == null) return 'That name cannot be used.';
    if (valid == entry.name) return null;
    if (_entries.any((e) => e.name == valid)) {
      return '"$valid" already exists here.';
    }
    final from = joinPath(_path, entry.name);
    final to = joinPath(_path, valid);
    if (_sudo && browsedServer != null && _browsedShare == null) {
      await _sudoMutation(
        'mv -- ${shellQuote(from)} ${shellQuote(to)}',
        success: 'Renamed to $valid (sudo)',
      );
    } else {
      await _mutate(
        (client) => client.rename(from, to, isDirectory: entry.isDirectory),
        success: 'Renamed to $valid',
      );
    }
    return null;
  }

  /// Deletes [entries]. The caller confirms first — this does not ask.
  Future<void> deleteEntries(List<SftpFile> entries) async {
    if (entries.isEmpty) return;
    if (_sudo && browsedServer != null && _browsedShare == null) {
      final paths = entries.map((entry) => shellQuote(joinPath(_path, entry.name))).join(' ');
      await _sudoMutation(
        'rm -rf -- $paths',
        success: 'Deleted ${entries.length} item${entries.length == 1 ? '' : 's'} (sudo)',
      );
      return;
    }
    await _mutate((client) async {
      for (final entry in entries) {
        await client.delete(joinPath(_path, entry.name), isDirectory: entry.isDirectory);
      }
    }, success: 'Deleted ${entries.length} item${entries.length == 1 ? '' : 's'}');
  }

  Future<void> _sudoMutation(String script, {required String success}) async {
    final server = browsedServer;
    final ssh = transport;
    if (server == null || ssh == null) return;
    _loading = true;
    _error = null;
    _safeNotify();
    String? failure;
    try {
      final credentials = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      final output = await ssh.exec(
        credentials,
        sudoShWrap(script, server.sudoPassword),
        stdin: sudoStdin(server.sudoPassword),
      );
      // The whole output rather than its first line: this runs archive and compression scripts,
      // whose own failures arrive after several lines of progress.
      if (hasSudoFailureMarker(output)) failure = output.trim();
    } catch (error) {
      failure = error.toString();
    }
    _loading = false;
    await refresh();
    _error = failure;
    _status = failure == null ? success : null;
    _safeNotify();
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

  /// Seeded on a host with no saved list, so the star column is useful before the user has
  /// bookmarked anything. These are where an administrator actually goes.
  ///
  /// Seeded **in memory only**, matching `loadSftpBookmarks` (`ui/AppViewModel.kt:9006`): they are
  /// never written to settings, so the cross-endpoint list below shows only what the user actually
  /// saved rather than five suggestions per host they have never opened.
  static const defaultBookmarks = ['/root', '/var/log', '/etc', '/opt', '/home'];

  /// The settings row the browse target's bookmarks live in, or null with nothing being browsed.
  String? get _currentBookmarkKey => bookmarkStorageKey(
    serverId: _browsedShare == null ? browsedServer?.id : null,
    shareId: _browsedShare?.id,
  );

  Future<void> _loadBookmarks(int serverId) =>
      _loadBookmarksFrom(bookmarkStorageKey(serverId: serverId)!, seedDefaults: true);

  /// Loads the star list for whatever is being browsed.
  ///
  /// [seedDefaults] only for hosts: `/etc` and `/var/log` are paths on a Unix machine, and offering
  /// them on an SMB share would be five bookmarks that all fail to open.
  Future<void> _loadBookmarksFrom(String key, {required bool seedDefaults}) async {
    final stored = decodeBookmarkPaths(await _app.repository.getSetting(key));
    _bookmarks = stored.isEmpty && seedDefaults ? defaultBookmarks : stored;
    _safeNotify();
  }

  bool isBookmarked(String path) => _bookmarks.contains(normalisePath(path));

  /// True whenever something is being browsed — a host or a share.
  ///
  /// Shares are bookmarkable too: they are stored under their own `share_bookmarks_{id}` row, which
  /// is the same row the Kotlin app and the backup format already use.
  bool get canBookmark => _currentBookmarkKey != null;

  Future<void> toggleBookmark(String path) async {
    final key = _currentBookmarkKey;
    if (key == null) return;
    final normalised = normalisePath(path);
    _bookmarks = _bookmarks.contains(normalised)
        ? _bookmarks.where((b) => b != normalised).toList()
        : [..._bookmarks, normalised];
    notifyListeners();
    await _app.repository.insertSetting(key, encodeBookmarkPaths(_bookmarks));
    // The cross-endpoint list is what the Bookmarks tab draws; a star set here must show up there.
    await loadAllBookmarks();
  }

  /// Jumps to [bookmark] on the endpoint already being browsed, switching to the browser tab.
  Future<void> openBookmark(String bookmark) async {
    if (!hasBrowseTarget) return;
    _activeTab = SftpTab.files;
    notifyListeners();
    await openPath(bookmark);
  }

  // ── bookmarks across every endpoint ─────────────────────────────────────────

  /// Every saved bookmark on every host and share, for the Bookmarks tab.
  ///
  /// Separate from [bookmarks], which is only the browse target's and drives the star toggle. The
  /// tab spans endpoints so it can be used *before* connecting to anything — which is the state the
  /// user is in when a jump list is most useful.
  List<EndpointBookmark> _allBookmarks = const [];

  List<EndpointBookmark> get allBookmarks => List.unmodifiable(_allBookmarks);

  /// Shares, cached from the last [loadAllBookmarks] so rows can be greyed without a query per
  /// paint. Empty until the tab has loaded once.
  List<NetworkShare> _bookmarkShares = const [];

  List<NetworkShare> get bookmarkShares => List.unmodifiable(_bookmarkShares);

  /// Hosts and shares a bookmark can be filed against, in the editor's order.
  List<Server> get bookmarkServers => _app.servers;

  /// How a share is named in the bookmark list, from `shareEndpointLabel`
  /// (`ui/AppViewModel.kt:7853`). The protocol is part of the name because one NAS is commonly
  /// saved twice, once per protocol.
  static String shareEndpointLabel(NetworkShare share) => '${share.name} (${share.protocol})';

  /// Rebuilds [allBookmarks] from every endpoint's settings row.
  Future<void> loadAllBookmarks() async {
    final shares = await _app.repository.getAllNetworkShares();
    final collected = <EndpointBookmark>[];
    for (final server in _app.servers) {
      final key = bookmarkStorageKey(serverId: server.id)!;
      for (final path in decodeBookmarkPaths(await _app.repository.getSetting(key))) {
        collected.add(EndpointBookmark(serverId: server.id, endpointName: server.name, path: path));
      }
    }
    for (final share in shares) {
      final key = bookmarkStorageKey(shareId: share.id)!;
      for (final path in decodeBookmarkPaths(await _app.repository.getSetting(key))) {
        collected.add(
          EndpointBookmark(shareId: share.id, endpointName: shareEndpointLabel(share), path: path),
        );
      }
    }
    _bookmarkShares = shares;
    _allBookmarks = collected;
    _safeNotify();
  }

  /// Whether [bookmark]'s endpoint can be opened right now.
  ///
  /// A host must be probed online, because opening one dials SFTP over an existing session. A share
  /// only has to not have failed its last test — browsing dials it from scratch, so an untested
  /// share is still worth attempting.
  bool bookmarkIsAvailable(EndpointBookmark bookmark) {
    if (bookmark.serverId != null) {
      return _app.servers.any((s) => s.id == bookmark.serverId && s.status == 'online');
    }
    final share = _shareFor(bookmark.shareId);
    return share != null && !shareIsUnavailable(share.lastStatus);
  }

  NetworkShare? _shareFor(int? id) {
    if (id == null) return null;
    for (final share in _bookmarkShares) {
      if (share.id == id) return share;
    }
    return null;
  }

  /// Removes [path] from the settings row [key], leaving the row's other entries alone.
  Future<void> _removeStoredBookmark(String key, String path) async {
    final remaining = decodeBookmarkPaths(
      await _app.repository.getSetting(key),
    ).where((p) => p != path);
    await _app.repository.insertSetting(key, encodeBookmarkPaths(remaining));
  }

  /// Deletes [bookmark] from whichever endpoint owns it.
  Future<void> removeEndpointBookmark(EndpointBookmark bookmark) async {
    final key = bookmark.storageKey;
    if (key == null) return;
    await _removeStoredBookmark(key, bookmark.path);
    // Keep the star in the browser in step, so a bookmark deleted here does not still show filled
    // on the folder it pointed at.
    if (key == _currentBookmarkKey) {
      _bookmarks = _bookmarks.where((p) => p != bookmark.path).toList();
    }
    await loadAllBookmarks();
  }

  /// Files a bookmark against an explicitly chosen endpoint — the tab's add, edit and clone flows.
  ///
  /// When [replacing] is given the old entry is removed first, so an edit that moves a bookmark to a
  /// different host is one operation rather than a delete the user has to remember to do.
  Future<void> saveEndpointBookmark({
    int? serverId,
    int? shareId,
    required String path,
    EndpointBookmark? replacing,
  }) async {
    final key = bookmarkStorageKey(serverId: serverId, shareId: shareId);
    if (key == null) return;
    final normalised = normaliseBookmarkPath(path);
    final oldKey = replacing?.storageKey;
    if (oldKey != null) {
      await _removeStoredBookmark(oldKey, replacing!.path);
      if (oldKey == _currentBookmarkKey) {
        _bookmarks = _bookmarks.where((p) => p != replacing.path).toList();
      }
    }
    final existing = decodeBookmarkPaths(await _app.repository.getSetting(key));
    if (!existing.contains(normalised)) {
      await _app.repository.insertSetting(key, encodeBookmarkPaths([...existing, normalised]));
    }
    if (key == _currentBookmarkKey && !_bookmarks.contains(normalised)) {
      _bookmarks = [..._bookmarks, normalised];
    }
    await loadAllBookmarks();
  }

  /// Follows [bookmark] to its endpoint, switching hosts or opening the share as needed.
  ///
  /// Availability is re-checked here as well as in the UI: the list is drawn from a snapshot, and a
  /// host that dropped offline since the last paint must not be dialled by a stale tap.
  Future<void> openEndpointBookmark(EndpointBookmark bookmark) async {
    if (!bookmarkIsAvailable(bookmark)) return;
    if (bookmark.serverId != null) {
      // Leave any share first: it owns the Files tab while open, and its listing would otherwise
      // stay on screen under the host's name.
      if (_browsedShare != null) {
        _browsedShare = null;
        _entries = const [];
      }
      if (_app.selectedServerId != bookmark.serverId) {
        // Sets _lastServerId ahead of the notification so the host-change handler does not reset
        // the path out from under the listing this is about to start.
        _lastServerId = bookmark.serverId;
        _app.selectedServerId = bookmark.serverId;
      }
      await _loadBookmarks(bookmark.serverId!);
      _activeTab = SftpTab.files;
      _safeNotify();
      await openPath(bookmark.path);
      return;
    }
    final share = _shareFor(bookmark.shareId);
    if (share == null) return;
    await openShare(share);
    await openPath(bookmark.path);
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
  /// Downloads [entry] to a temporary file and returns its path, or null when it failed.
  ///
  /// Staged to disk rather than held in memory: a remote file can be gigabytes, and buffering it to
  /// hand to the save dialog would fail on exactly the transfers most worth doing. The caller is
  /// responsible for deleting the staging file — [downloadToDevice] does.
  Future<String?> _downloadToTemp(SftpFile entry) async {
    final directory = await Directory.systemTemp.createTemp('omniterm-dl-');
    final staged = File('${directory.path}/${entry.name}');
    final sink = staged.openWrite();
    try {
      await download(entry, sink);
      await sink.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      await directory.delete(recursive: true).catchError((Object _) => directory);
      return null;
    }
    if (_transfers.isNotEmpty && _transfers.last.status == TransferStatus.failed) {
      await directory.delete(recursive: true).catchError((Object _) => directory);
      return null;
    }
    return staged.path;
  }

  // ── image preview ───────────────────────────────────────────────────────────

  RemoteImagePreview? _imagePreview;

  /// The image being previewed, or null when the overlay is closed.
  RemoteImagePreview? get imagePreview => _imagePreview;

  /// Identifies the fetch in flight, so a preview closed and reopened cannot be overwritten by the
  /// first download landing late.
  int _imagePreviewToken = 0;

  void closeImagePreview() {
    // Bumped before clearing, so an in-flight download drops its bytes rather than reopening the
    // overlay the user just dismissed — and the decoded image is released with it.
    _imagePreviewToken++;
    if (_imagePreview == null) return;
    _imagePreview = null;
    _safeNotify();
  }

  /// Fetches [entry] into memory and shows it.
  ///
  /// Held in memory rather than staged to disk, unlike [downloadToDevice]: this is a look, not a
  /// copy, and writing a remote image into the cache to display it would leave it there.
  Future<void> openImagePreview(SftpFile entry) async {
    if (!isImageFile(entry.name)) return;
    final token = ++_imagePreviewToken;

    if (imagePreviewTooLarge(entry.size)) {
      // Refused before the download, not after: the point of a ceiling is to not spend the transfer.
      _imagePreview = RemoteImagePreview(
        name: entry.name,
        sizeBytes: entry.size,
        error:
            'Too large to preview (${humanBytes(entry.size)}; '
            'limit ${humanBytes(imagePreviewMaxBytes)}). Download it instead.',
      );
      _safeNotify();
      return;
    }

    _imagePreview = RemoteImagePreview(
      name: entry.name,
      sizeBytes: entry.size,
      progress: entry.size > 0 ? 0 : null,
    );
    _safeNotify();

    final buffer = BytesBuilder(copy: false);
    final sink = _CollectingSink(buffer);
    try {
      final client = await _client;
      if (client == null) throw StateError('no file connection');
      // Straight to the client rather than through [download]: that records a Transfers row, and a
      // row per image glanced at would bury the transfers the user actually started.
      await client.downloadTo(
        joinPath(_path, entry.name),
        sink,
        onProgress: (copied, total) {
          if (token != _imagePreviewToken) return;
          _imagePreview = RemoteImagePreview(
            name: entry.name,
            sizeBytes: entry.size,
            progress: total > 0 ? (copied / total).clamp(0.0, 1.0) : null,
          );
          _safeNotify();
        },
      );
      if (token != _imagePreviewToken) return;
      _imagePreview = RemoteImagePreview(
        name: entry.name,
        sizeBytes: entry.size,
        bytes: buffer.takeBytes(),
      );
    } catch (e) {
      if (token != _imagePreviewToken) return;
      _imagePreview = RemoteImagePreview(
        name: entry.name,
        sizeBytes: entry.size,
        error: 'Could not load "${entry.name}": $e',
      );
    }
    _safeNotify();
  }

  /// The selected rows a batch download would actually move.
  ///
  /// **Files only**, matching `selectedRemoteFileNames` (`ui/SftpScreen.kt:1556`). A directory has
  /// no bytes to hand to a save dialog, and silently walking into one would download a tree the user
  /// selected a single row for.
  List<SftpFile> get selectedFilesForDownload =>
      selectedEntries.where((e) => !e.isDirectory).toList();

  /// Whether a batch download has anything to do.
  bool get canBatchDownload => selectedFilesForDownload.isNotEmpty;

  /// Total size of what a batch download would fetch, for the warning.
  int get selectedDownloadBytes => selectedFilesForDownload.fold<int>(
    0,
    (sum, entry) => sum + (entry.size < 0 ? 0 : entry.size),
  );

  /// Whether a batch download is big enough to warn about first.
  ///
  /// Separate from [selectedTransferNeedsWarning], which counts directories because a cross-host
  /// paste carries them; this flow does not.
  bool get batchDownloadNeedsWarning =>
      selectedFilesForDownload.length >= _app.sftpLargeBatchFileThreshold ||
      selectedDownloadBytes >= _app.sftpLargeBatchBytesThreshold;

  /// The largest single file a batch download will attempt, in bytes.
  ///
  /// The platform's save-into-a-folder API takes **bytes, not a path**, so each file is briefly held
  /// in memory — unlike [downloadToDevice], which streams by path. Rather than let a large file take
  /// the app down mid-batch, anything above this is skipped with a message pointing at the per-file
  /// download, which has no such limit. 256 MB is comfortably above configuration files and logs,
  /// which is what people multi-select, and well below what a phone will refuse to allocate.
  static const int batchDownloadByteCeiling = 256 * 1024 * 1024;

  /// Downloads every selected file into one folder the user picks once.
  ///
  /// Ported from `sftpDownloadFilesToFolder` (`ui/AppViewModel.kt:9717`). Flutter could only
  /// download one entry at a time from the row menu, so twelve files meant twelve save dialogs.
  ///
  /// **One file failing does not end the batch.** The first error is kept and reported alongside how
  /// many did land, because the useful thing after a partial download is knowing which files to go
  /// back for — not losing the eleven that worked.
  Future<void> downloadSelectedToFolder(DeviceFileStore store) async {
    final files = selectedFilesForDownload;
    if (files.isEmpty) return;

    final folder = await store.pickFolder();
    // A cancelled picker is not a failure: nothing was promised and nothing was moved.
    if (folder == null) return;

    _error = null;
    _status = null;
    _safeNotify();

    var saved = 0;
    String? firstError;
    for (final entry in files) {
      if (entry.size > batchDownloadByteCeiling) {
        firstError ??=
            '${entry.name} is too large for a batch download — '
            'use "Download to device" on the row itself.';
        continue;
      }
      final staged = await _downloadToTemp(entry);
      if (staged == null) {
        firstError ??= 'Could not download "${entry.name}".';
        continue;
      }
      final result = await store.saveInto(folder, entry.name, staged);
      // Removed whether or not the save worked, for the same reason the single-file path removes
      // it: a copy of a remote file left in the cache quietly widens access to it.
      await File(staged).parent.delete(recursive: true).catchError((Object _) => Directory(staged));
      switch (result.outcome) {
        case DeviceSaveOutcome.saved:
          saved++;
        case DeviceSaveOutcome.cancelled:
          firstError ??= 'Saving "${entry.name}" was cancelled.';
        case DeviceSaveOutcome.failed:
          firstError ??= 'Could not save "${entry.name}": ${result.error}';
      }
    }

    // Only what was attempted leaves the selection, so a folder the user also had selected is still
    // selected afterwards rather than silently dropped.
    _selected.removeAll(files.map((e) => e.name));
    _error = firstError;
    _status = firstError == null
        ? 'Downloaded ${files.length} file(s) to your device.'
        : 'Downloaded $saved of ${files.length} file(s) — see the error above.';
    _safeNotify();
  }

  /// Downloads [entry] and hands it to the platform's save dialog.
  ///
  /// Ported from the download action in `ui/SftpScreen.kt`. Flutter had `download` on this view
  /// model and no caller anywhere in the UI, so the Transfers tab could only ever show transfers
  /// that some other flow had started.
  Future<void> downloadToDevice(SftpFile entry, DeviceFileStore store) async {
    final staged = await _downloadToTemp(entry);
    if (staged == null) {
      _error ??= 'Could not download "${entry.name}".';
      _safeNotify();
      return;
    }
    final result = await store.save(entry.name, staged);
    // Removed whether or not the save worked: leaving a copy of a remote file in the cache is a
    // quiet way to widen access to it, and the user did not ask for a second copy.
    await File(staged).parent.delete(recursive: true).catchError((Object _) => Directory(staged));
    switch (result.outcome) {
      case DeviceSaveOutcome.saved:
        _status = result.location == null
            ? 'Saved "${entry.name}" to your device.'
            : 'Saved "${entry.name}" to ${result.location}';
      case DeviceSaveOutcome.cancelled:
        // Silent on purpose: the user backed out, and the staging copy is already gone.
        break;
      case DeviceSaveOutcome.failed:
        _error = 'Could not save "${entry.name}": ${result.error}';
    }
    _safeNotify();
  }

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

  /// The size of a file on this device, or 0 when it cannot be read.
  ///
  /// Zero rather than an error: the size only decides whether to warn, and failing to stat a file
  /// the user just picked should not stop the upload that would report the real problem.
  Future<int> sizeOfLocalFile(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  /// Uploads the file at [sourcePath] into the current directory.
  ///
  /// Streamed from disk rather than read into memory: the file is the user's own and can be any
  /// size. The remote name comes from the source's basename and is de-duplicated by [upload], so an
  /// upload never silently replaces something already there.
  Future<void> uploadFromDevice(String sourcePath) async {
    final file = File(sourcePath);
    final int size;
    try {
      size = await file.length();
    } catch (e) {
      _error = 'Could not read the file you picked: $e';
      _safeNotify();
      return;
    }
    await upload(baseName(sourcePath), file.openRead(), size);
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

/// Collects a download into memory for the image preview.
///
/// [RemoteFsClient.downloadTo] writes to a sink; the preview wants the bytes, not a file. Nothing is
/// written to disk, which is the point — a preview is a look, not a copy.
class _CollectingSink implements StreamSink<List<int>> {
  _CollectingSink(this._buffer);

  final BytesBuilder _buffer;
  final _done = Completer<void>();

  @override
  void add(List<int> data) => _buffer.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() {
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}
