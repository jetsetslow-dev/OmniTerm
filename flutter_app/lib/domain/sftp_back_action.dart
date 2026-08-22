/// What Android Back should do while the SFTP screen is on top.
///
/// Ported from the two `BackHandler`s in `ui/SftpScreen.kt` (lines 647 and 1691) and the one in
/// `ui/ImagePreview.kt:56`. Kotlin expresses this as three separate handlers whose enablement
/// conditions happen not to overlap; collapsing them into one ordered decision keeps that
/// non-overlap a property of the code rather than a coincidence of where the handlers were
/// installed.
enum SftpBackAction {
  /// Nothing on this screen claims the press — let it reach the app's own navigation.
  none,

  /// Dismiss the full-screen image preview.
  closePreview,

  /// Leave selection mode, keeping the listing where it is.
  clearSelection,

  /// Dismiss search results and return to the directory listing.
  clearSearch,

  /// Move to the parent directory.
  goUp,

  /// Leave the network share and go back to browsing hosts.
  closeShare,
}

/// Resolves the single thing Back should do, given everything the screen is currently showing.
///
/// The order is Kotlin's, and it matters: Back peels one layer of state at a time rather than
/// jumping straight out. A file browser where Back leaves the screen from three directories deep
/// is the defect this replaces.
///
/// Two asymmetries are deliberate, both inherited:
///
/// * The preview is checked before [onFilesTab] because Kotlin draws it above the whole app and
///   disables the app-level handler while it is up (`ui/AppUi.kt:482`). It is not part of the tab.
/// * A share at its root closes the browser, while a *host* at its root does not claim the press
///   at all — Kotlin's host handler is explicitly `enabled = … || (path != "" && path != "/")`,
///   so Back at a host's root leaves the screen. A share has somewhere to go back *to* (the share
///   list); a host does not.
SftpBackAction sftpBackAction({
  required bool previewOpen,
  required bool onFilesTab,
  required bool hasSelection,
  required bool searchResultsShown,
  required String path,
  required bool shareOpen,
}) {
  if (previewOpen) return SftpBackAction.closePreview;
  if (!onFilesTab) return SftpBackAction.none;
  if (hasSelection) return SftpBackAction.clearSelection;
  if (searchResultsShown) return SftpBackAction.clearSearch;
  // An empty path is the not-yet-resolved home directory, which has no parent to walk to.
  if (path.isNotEmpty && path != '/') return SftpBackAction.goUp;
  return shareOpen ? SftpBackAction.closeShare : SftpBackAction.none;
}
