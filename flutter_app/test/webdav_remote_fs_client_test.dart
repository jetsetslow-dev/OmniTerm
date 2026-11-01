import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/shares/webdav_remote_fs_client.dart';

void main() {
  test('WebDAV collection paths are encoded and end in a slash', () {
    expect(webDavResourcePath('/team files/café', collection: true), '/team%20files/caf%C3%A9/');
    expect(webDavResourcePath('/', collection: true), '/');
  });

  test('WebDAV file paths do not gain a collection slash', () {
    expect(webDavResourcePath('/fixture.txt'), '/fixture.txt');
  });

  group('getlastmodified is an HTTP-date, not ISO 8601', () {
    test('an RFC 1123 date is parsed', () {
      // `DateTime.tryParse` returns null for this, which is the format RFC 4918 requires. Relying on
      // it alone gave every file on every WebDAV share a modified time of zero: no date shown, and
      // sorting by date ranked everything equal without ever looking wrong.
      expect(parseWebDavDate('Tue, 11 Aug 2026 10:00:00 GMT'), DateTime.utc(2026, 8, 11, 10, 0, 0));
      expect(DateTime.tryParse('Tue, 11 Aug 2026 10:00:00 GMT'), isNull, reason: 'why this exists');
    });

    test('a single-digit day and every month name are handled', () {
      expect(parseWebDavDate('Wed, 9 Jun 2021 22:33:44 GMT'), DateTime.utc(2021, 6, 9, 22, 33, 44));
      for (final (index, month) in [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ].indexed) {
        expect(
          parseWebDavDate('Mon, 01 $month 2024 00:00:00 GMT'),
          DateTime.utc(2024, index + 1, 1),
          reason: month,
        );
      }
    });

    test('ISO is still accepted, because some servers send it anyway', () {
      expect(parseWebDavDate('2026-08-11T10:00:00Z'), DateTime.utc(2026, 8, 11, 10));
    });

    test('nonsense is null rather than an invented time', () {
      expect(parseWebDavDate(''), isNull);
      expect(parseWebDavDate('not a date'), isNull);
      expect(parseWebDavDate('Xyz, 99 Foo 2026 10:00:00 GMT'), isNull);
    });
  });

  group('an href may be an absolute URL or a path', () {
    test('the scheme and authority are stripped', () {
      // RFC 4918 allows both, and real servers send both. Comparing a raw absolute href against the
      // requested path meant a collection never matched itself and appeared inside its own listing.
      expect(webDavHrefToPath('http://nas.local/fixture/file.txt'), '/fixture/file.txt');
      expect(webDavHrefToPath('https://nas.local:8443/fixture/'), '/fixture/');
      expect(webDavHrefToPath('/fixture/file.txt'), '/fixture/file.txt');
    });

    test('an absolute URL with no path becomes the root', () {
      expect(webDavHrefToPath('http://nas.local'), '/');
    });

    test('percent-encoding is decoded either way', () {
      expect(webDavHrefToPath('http://nas.local/team%20files/caf%C3%A9'), '/team files/café');
      expect(webDavHrefToPath('/team%20files'), '/team files');
    });

    test('a malformed encoding is used verbatim rather than dropped', () {
      expect(webDavHrefToPath('/broken%zz'), '/broken%zz');
    });
  });
}
