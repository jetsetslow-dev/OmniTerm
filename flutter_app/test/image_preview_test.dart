import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/image_preview.dart';

/// Previewing a remote image, ported from `isImageFile` / `loadImagePreview`
/// (`ui/AppViewModel.kt:8122`, `:8140`).
///
/// Flutter had no viewer at all: tapping an image fell through to the *text* editor, which decodes
/// the bytes as UTF-8 and offers to save them back.
void main() {
  group('what counts as an image', () {
    test('the nine extensions Kotlin lists', () {
      for (final ext in previewableImageExtensions) {
        expect(isImageFile('holiday.$ext'), isTrue, reason: ext);
      }
    });

    test('the extension is matched whatever case it is written in', () {
      // Servers and cameras disagree about this constantly.
      expect(isImageFile('IMG_0001.JPG'), isTrue);
      expect(isImageFile('scan.PnG'), isTrue);
    });

    test('only the last extension counts', () {
      expect(isImageFile('archive.png.gz'), isFalse);
      expect(isImageFile('backup.tar.png'), isTrue);
    });

    test('things that are not images are left to the editor', () {
      expect(isImageFile('nginx.conf'), isFalse);
      expect(isImageFile('notes.txt'), isFalse);
      expect(isImageFile('README'), isFalse);
    });

    test('a dotfile is not an image with a strange name', () {
      // `.png` would otherwise read as a file whose extension is `png`.
      expect(isImageFile('.png'), isFalse);
      expect(isImageFile('.bashrc'), isFalse);
    });

    test('a trailing dot leaves no extension', () {
      expect(isImageFile('broken.'), isFalse);
    });
  });

  group('the size ceiling', () {
    test('an ordinary photo is fine', () {
      expect(imagePreviewTooLarge(4 * 1024 * 1024), isFalse);
    });

    test('past the ceiling is refused', () {
      expect(imagePreviewTooLarge(imagePreviewMaxBytes + 1), isTrue);
      expect(imagePreviewTooLarge(imagePreviewMaxBytes), isFalse);
    });

    test('an unreported size is not treated as huge', () {
      // The ceiling exists to avoid spending a known-large download. Refusing a file whose size the
      // server merely did not report would block the common case on such a server.
      expect(imagePreviewTooLarge(0), isFalse);
      expect(imagePreviewTooLarge(-1), isFalse);
    });
  });

  group('the preview state', () {
    test('loading is neither bytes nor an error', () {
      const p = RemoteImagePreview(name: 'a.png', sizeBytes: 10, progress: 0.5);
      expect(p.isLoading, isTrue);
    });

    test('a failure is not loading', () {
      const p = RemoteImagePreview(name: 'a.png', sizeBytes: 10, error: 'nope');
      expect(p.isLoading, isFalse);
    });

    test('bytes arriving ends the load', () {
      const p = RemoteImagePreview(name: 'a.png', sizeBytes: 2, bytes: [1, 2]);
      expect(p.isLoading, isFalse);
    });
  });
}
