/// Bookmarks that belong to a specific endpoint — an SSH host or a network share.
///
/// Ported from `EndpointBookmark` and the endpoint-scoped bookmark store in `ui/AppViewModel.kt`
/// (`:9039`–`:9180`).
///
/// Flutter stored bookmarks per host and showed only the host currently being browsed, so the
/// Bookmarks tab was empty until a host was online and could never name the machine a path belonged
/// to. Kotlin's tab is a jump list across *every* saved endpoint, which is the only thing that makes
/// it useful before you have connected to anything.
library;

/// One bookmarked path on one endpoint.
///
/// Exactly one of [serverId] and [shareId] is set: a path is meaningful on the machine it was saved
/// from and nowhere else, so a bookmark with both — or neither — has no endpoint to open.
class EndpointBookmark {
  const EndpointBookmark({
    this.serverId,
    this.shareId,
    required this.endpointName,
    required this.path,
  });

  final int? serverId;
  final int? shareId;

  /// How the endpoint is named in the list — the host's name, or the share's name and protocol.
  ///
  /// Carried on the bookmark rather than looked up at paint time so a row for an endpoint that has
  /// since been deleted still says what it pointed at instead of rendering blank.
  final String endpointName;

  final String path;

  bool get isShare => shareId != null;

  /// True when this bookmark names an endpoint at all.
  ///
  /// A row that identifies neither a host nor a share cannot be opened, edited or deleted — there is
  /// no settings key to write it back to — so it is dropped rather than shown as a dead entry.
  bool get hasEndpoint => serverId != null || shareId != null;

  /// The settings row this bookmark lives in.
  String? get storageKey => bookmarkStorageKey(serverId: serverId, shareId: shareId);

  EndpointBookmark copyWith({String? endpointName, String? path}) => EndpointBookmark(
    serverId: serverId,
    shareId: shareId,
    endpointName: endpointName ?? this.endpointName,
    path: path ?? this.path,
  );

  /// Identity is the endpoint plus the path — [endpointName] is display only, so a host rename must
  /// not make an existing bookmark look like a different one and duplicate it in the list.
  @override
  bool operator ==(Object other) =>
      other is EndpointBookmark &&
      other.serverId == serverId &&
      other.shareId == shareId &&
      other.path == path;

  @override
  int get hashCode => Object.hash(serverId, shareId, path);

  @override
  String toString() => 'EndpointBookmark($endpointName:$path)';
}

/// Which settings row holds an endpoint's bookmarks, or null when neither id is set.
///
/// `sftp_bookmarks_{serverId}` is the historical host format — unchanged so bookmarks saved by the
/// Kotlin app survive a restore — and `share_bookmarks_{shareId}` mirrors it for shares.
String? bookmarkStorageKey({int? serverId, int? shareId}) {
  if (serverId != null) return 'sftp_bookmarks_$serverId';
  if (shareId != null) return 'share_bookmarks_$shareId';
  return null;
}

/// The separator Kotlin joins bookmark paths with inside one settings row.
const String bookmarkSeparator = '|||';

/// Splits a stored bookmark row into paths.
///
/// Blank segments are dropped rather than kept as empty rows: a trailing separator is what a
/// single-entry list looks like after a removal, and an empty path would render as a nameless
/// bookmark that opens the wrong directory.
List<String> decodeBookmarkPaths(String? raw) {
  if (raw == null) return const [];
  return raw
      .split(bookmarkSeparator)
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
}

String encodeBookmarkPaths(Iterable<String> paths) => paths.join(bookmarkSeparator);

/// Tidies a path typed into the bookmark editor.
///
/// A blank entry becomes the root rather than being rejected: the user asked to bookmark *something*
/// on that endpoint, and the root is the only path that is certainly valid there.
String normaliseBookmarkPath(String path) {
  final trimmed = path.trim();
  return trimmed.isEmpty ? '/' : trimmed;
}

/// Share statuses that mean a browse attempt has already been tried and failed.
///
/// Ported from `shareUnavailable` (`ui/AppViewModel.kt:12115`).
const Set<String> unavailableShareStatuses = {
  'unreachable',
  'offline',
  'failed',
  'error',
};

/// Whether a share whose last probe reported [lastStatus] is worth offering.
///
/// An **untested** share stays available: browsing dials it anyway, and greying out everything the
/// user has not happened to probe yet would make a freshly restored backup look broken.
bool shareIsUnavailable(String lastStatus) =>
    unavailableShareStatuses.contains(lastStatus.toLowerCase());
