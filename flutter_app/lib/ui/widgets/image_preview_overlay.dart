import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/remote_parsers.dart';
import '../../domain/image_preview.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// A remote image shown in place, ported from `ImagePreviewOverlay` and `ZoomableImage`
/// (`ui/ImagePreview.kt`).
///
/// Full-screen and modal: an image is worth the whole screen on a phone, and the browser underneath
/// would be unusable behind it anyway.
class ImagePreviewOverlay extends StatelessWidget {
  const ImagePreviewOverlay({super.key, required this.preview, required this.onClose});

  final RemoteImagePreview preview;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('sftp.imagePreview'),
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        preview.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: OmniFonts.mono,
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                      if (preview.sizeBytes > 0)
                        Text(
                          humanBytes(preview.sizeBytes),
                          style: const TextStyle(fontSize: 11, color: OmniColors.textSecondary),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close image preview',
                  key: const ValueKey('sftp.imagePreview.close'),
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: onClose,
                ),
              ],
            ),
            Expanded(child: Center(child: _body())),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final error = preview.error;
    if (error != null) {
      return Padding(
        key: const ValueKey('sftp.imagePreview.error'),
        padding: const EdgeInsets.all(24),
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: OmniColors.red),
        ),
      );
    }

    final bytes = preview.bytes;
    if (bytes == null) {
      return Column(
        key: const ValueKey('sftp.imagePreview.loading'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 160,
            // Determinate only when the size was known in advance; a bar pinned at zero because
            // nothing reported a total reads as stalled.
            child: LinearProgressIndicator(value: preview.progress, minHeight: 3),
          ),
          const SizedBox(height: 10),
          const Text('Loading…', style: TextStyle(fontSize: 12, color: OmniColors.textSecondary)),
        ],
      );
    }

    return InteractiveViewer(
      key: const ValueKey('sftp.imagePreview.image'),
      minScale: 1,
      maxScale: 8,
      child: Image.memory(
        Uint8List.fromList(bytes),
        fit: BoxFit.contain,
        // A file whose extension promised an image and whose bytes are not one — a truncated
        // download, or a `.png` that never was. Saying so beats Flutter's default broken-image glyph,
        // which gives the user nothing to act on.
        errorBuilder: (context, _, _) => const Padding(
          key: ValueKey('sftp.imagePreview.undecodable'),
          padding: EdgeInsets.all(24),
          child: Text(
            'That file could not be decoded as an image.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: OmniColors.red),
          ),
        ),
      ),
    );
  }
}
