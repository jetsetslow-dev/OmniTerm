/// Previewing a remote image without saving it to the device.
///
/// Ported from `RemoteImagePreview`, `isImageFile` and `loadImagePreview`
/// (`ui/AppViewModel.kt:8105`–`:8180`) and `ImagePreviewOverlay` (`ui/ImagePreview.kt`).
///
/// Flutter had none of it: tapping an image in the browser fell through to the *text* editor, which
/// read the bytes as UTF-8 and offered to save them back — the one action guaranteed to corrupt the
/// file.
library;

/// Extensions the in-app viewer will attempt to decode.
///
/// The same nine Kotlin lists. Deliberately not "anything the platform might decode": an extension
/// this app does not claim is better opened by something that does, and a preview that fails after
/// a 40 MB download is worse than one that was never offered.
const Set<String> previewableImageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'avif',
};

/// The largest file the viewer will pull into memory.
///
/// The buffer is transient, but a runaway file would still take the heap with it — and on a phone
/// that is the whole app, not just the preview.
const int imagePreviewMaxBytes = 64 * 1024 * 1024;

/// Whether [name] is worth offering a preview for.
///
/// Matched on the extension alone, as Kotlin does. Sniffing the magic bytes would be more accurate
/// and would need the download this decides whether to start.
bool isImageFile(String name) {
  final dot = name.lastIndexOf('.');
  // A dot at the very end leaves no extension; `.bashrc` is a dotfile, not a `bashrc` image.
  if (dot < 1 || dot == name.length - 1) return false;
  return previewableImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Whether [sizeBytes] is beyond what the viewer will attempt.
///
/// A size the server never reported (0 or negative) is **not** treated as too large: the check
/// exists to stop a known-huge download, and refusing to preview a file whose size is merely unknown
/// would block the common case on a server that does not report sizes.
bool imagePreviewTooLarge(int sizeBytes) => sizeBytes > imagePreviewMaxBytes;

/// A remote image being fetched, decoded, or failed.
class RemoteImagePreview {
  const RemoteImagePreview({
    required this.name,
    required this.sizeBytes,
    this.bytes,
    this.error,
    this.progress,
  });

  final String name;
  final int sizeBytes;

  /// The encoded file, once it is all here. Null while loading or on failure.
  final List<int>? bytes;

  /// Why there is nothing to show. Null while loading and on success.
  final String? error;

  /// 0..1 while downloading when the size is known in advance, else null so the bar is
  /// indeterminate rather than pinned at zero — which reads as stalled.
  final double? progress;

  bool get isLoading => bytes == null && error == null;
}
