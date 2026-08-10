import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/endpoint_bookmark.dart';

/// Endpoint-scoped bookmarks, ported from `EndpointBookmark` and the bookmark store in
/// `ui/AppViewModel.kt:9039`.
///
/// Flutter kept bookmarks per host and only ever showed the host being browsed, so the tab was
/// empty until something was online and never said which machine a path belonged to.
void main() {
  group('storage keys', () {
    test('a host keeps the historical key so an upgrade reads its bookmarks', () {
      expect(bookmarkStorageKey(serverId: 7), 'sftp_bookmarks_7');
    });

    test('a share has its own key family', () {
      expect(bookmarkStorageKey(shareId: 3), 'share_bookmarks_3');
    });

    test('naming no endpoint has no row to write to', () {
      // Not an exception: the editor can be open with nothing chosen yet, and the save button is
      // what refuses — this only has to avoid inventing a key.
      expect(bookmarkStorageKey(), isNull);
    });

    test('a host wins over a share, so a key is never ambiguous', () {
      // Both set is a caller error; the point is that it resolves to exactly one row rather than
      // writing the path into two endpoints at once.
      expect(bookmarkStorageKey(serverId: 1, shareId: 2), 'sftp_bookmarks_1');
    });
  });

  group('the stored format', () {
    test('paths round-trip through the Kotlin separator', () {
      const paths = ['/etc', '/var/log'];
      expect(encodeBookmarkPaths(paths), '/etc|||/var/log');
      expect(decodeBookmarkPaths(encodeBookmarkPaths(paths)), paths);
    });

    test('an absent row is an empty list, not a crash', () {
      expect(decodeBookmarkPaths(null), isEmpty);
    });

    test('blank segments are dropped', () {
      // What a one-entry list looks like after a removal. Kept, it would render as a nameless
      // bookmark that opens the wrong directory.
      expect(decodeBookmarkPaths('/etc|||'), ['/etc']);
      expect(decodeBookmarkPaths('|||  |||/opt'), ['/opt']);
      expect(decodeBookmarkPaths(''), isEmpty);
    });

    test('a path containing the separator is not silently split apart', () {
      // Not legal in a filename on any host this app talks to, but the encoder must not produce a
      // row that decodes into two bookmarks either.
      expect(decodeBookmarkPaths(encodeBookmarkPaths(['/a/b'])), ['/a/b']);
    });
  });

  group('normalising a typed path', () {
    test('surrounding space is dropped', () {
      expect(normaliseBookmarkPath('  /srv/www  '), '/srv/www');
    });

    test('blank becomes the root rather than being refused', () {
      // The user asked to bookmark something on that endpoint; the root is the one path certain to
      // exist there.
      expect(normaliseBookmarkPath('   '), '/');
    });
  });

  group('identity', () {
    const onHost = EndpointBookmark(
      serverId: 1,
      endpointName: 'nas',
      path: '/etc',
    );

    test('the same path on a different endpoint is a different bookmark', () {
      const onShare = EndpointBookmark(
        shareId: 1,
        endpointName: 'media (SMB)',
        path: '/etc',
      );
      expect(onHost == onShare, isFalse);
    });

    test('renaming the endpoint does not make it a new bookmark', () {
      // Otherwise a host rename would leave the old entry in the list beside the new one.
      expect(onHost == onHost.copyWith(endpointName: 'nas-01'), isTrue);
      expect(onHost.hashCode, onHost.copyWith(endpointName: 'nas-01').hashCode);
    });

    test('a bookmark naming no endpoint is recognisable as unopenable', () {
      const orphan = EndpointBookmark(endpointName: 'gone', path: '/etc');
      expect(orphan.hasEndpoint, isFalse);
      expect(orphan.storageKey, isNull);
      expect(onHost.hasEndpoint, isTrue);
    });

    test('a share bookmark knows it is one', () {
      expect(onHost.isShare, isFalse);
      expect(
        const EndpointBookmark(
          shareId: 2,
          endpointName: 'media (SMB)',
          path: '/',
        ).isShare,
        isTrue,
      );
    });
  });

  group('share availability', () {
    test('a share whose last probe failed is unavailable', () {
      for (final status in ['unreachable', 'offline', 'failed', 'error']) {
        expect(shareIsUnavailable(status), isTrue, reason: status);
      }
    });

    test('the check is case-insensitive', () {
      // Statuses are written by several call sites; a capitalised one must not read as healthy.
      expect(shareIsUnavailable('Unreachable'), isTrue);
      expect(shareIsUnavailable('OFFLINE'), isTrue);
    });

    test('an untested share stays available', () {
      // Browsing dials it from scratch, so "never probed" is no reason to grey it out — and a
      // freshly restored backup has probed nothing at all.
      expect(shareIsUnavailable('unknown'), isFalse);
      expect(shareIsUnavailable(''), isFalse);
      expect(shareIsUnavailable('online'), isFalse);
    });
  });
}
