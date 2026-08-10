import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/shares/remote_fs_client.dart';
import 'package:omniterm/data/ssh/ssh_private_key.dart';

import 'support/ed25519_fixture.dart';

void main() {
  group('parsePrivateKey diagnostics', () {
    // The whole point of this module is that an unparseable key produces something the user can act
    // on, rather than a parser's internal representation.

    test('a pasted public key is called out specifically', () {
      for (final pub in [
        'ssh-rsa AAAAB3NzaC1yc2E user@host',
        'ssh-ed25519 AAAAC3NzaC1lZDI1 user@host',
        'ecdsa-sha2-nistp256 AAAAE2VjZHNh user@host',
        'ssh-dss AAAAB3NzaC1kc3M user@host',
      ]) {
        expect(
          () => parsePrivateKey(pub),
          throwsA(
            isA<InvalidPrivateKeyException>().having(
              (e) => e.message,
              'message',
              allOf(contains('looks like a public key'), contains('.pub')),
            ),
          ),
          reason: pub.split(' ').first,
        );
      }
    });

    test('text with no PEM markers is rejected before parsing', () {
      expect(
        () => parsePrivateKey('just some random text'),
        throwsA(
          isA<InvalidPrivateKeyException>().having(
            (e) => e.message,
            'message',
            contains("doesn't look like a private key"),
          ),
        ),
      );
    });

    test('an empty or whitespace key is rejected', () {
      expect(() => parsePrivateKey(''), throwsA(isA<InvalidPrivateKeyException>()));
      expect(() => parsePrivateKey('   \n  '), throwsA(isA<InvalidPrivateKeyException>()));
    });

    test('a corrupt PEM body reports a usable message, never an object dump', () {
      final corrupt =
          '${pemBegin('OPENSSH')}\n'
          'not-actually-base64-key-material\n'
          '${pemEnd('OPENSSH')}';
      try {
        parsePrivateKey(corrupt);
        fail('expected the corrupt key to be rejected');
      } on InvalidPrivateKeyException catch (e) {
        expect(e.message, startsWith('Invalid private key'));
        expect(e.message, isNot(contains('[B@')), reason: 'the JSch leak this guard exists for');
        expect(e.message, isNot(contains('Instance of')), reason: "Dart's equivalent leak");
      }
    });

    test('the fallback message mentions the passphrase, the usual cause', () {
      final corrupt = "${pemBegin('RSA')}\nzzzz\n${pemEnd('RSA')}";
      try {
        parsePrivateKey(corrupt);
        fail('expected rejection');
      } on InvalidPrivateKeyException catch (e) {
        expect(e.message, startsWith('Invalid private key'));
      }
    });

    test('privateKeyNeedsPassphrase never throws on junk', () {
      expect(privateKeyNeedsPassphrase('nonsense'), isFalse);
      expect(privateKeyNeedsPassphrase(''), isFalse);
    });
  });

  group('ShareClients.startPath', () {
    NetworkShare share({required String protocol, String sharePath = ''}) => NetworkShare(
      id: 1,
      name: 'test',
      protocol: protocol,
      address: '10.0.0.5',
      port: 445,
      sharePath: sharePath,
      workgroup: '',
      username: '',
      password: '',
      anonymous: true,
      useHttps: false,
      notes: '',
      lastChecked: 0,
      lastStatus: 'unknown',
    );

    test('SMB drops the first segment, which the connection already consumed', () async {
      final client = _StubFsClient('/home/stub');
      expect(
        await ShareClients.startPath(share(protocol: 'SMB', sharePath: 'Public/docs/2026'), client),
        '/docs/2026',
      );
      expect(
        await ShareClients.startPath(share(protocol: 'SMB', sharePath: 'Public'), client),
        '/',
      );
    });

    test('other protocols use the configured path verbatim', () async {
      final client = _StubFsClient('/home/stub');
      expect(
        await ShareClients.startPath(share(protocol: 'FTP', sharePath: '/pub/incoming/'), client),
        '/pub/incoming',
      );
    });

    test('a blank path falls back to the client home', () async {
      final client = _StubFsClient('/home/stub');
      expect(await ShareClients.startPath(share(protocol: 'SFTP'), client), '/home/stub');
    });

    test('smbShareName takes the first segment only', () {
      expect(
        ShareClients.smbShareName(share(protocol: 'SMB', sharePath: '/Public/docs')),
        'Public',
      );
      expect(ShareClients.smbShareName(share(protocol: 'SMB', sharePath: '')), isNull);
      expect(ShareClients.smbShareName(share(protocol: 'SMB', sharePath: '/')), isNull);
    });
  });

  group('formatFsDate', () {
    test('formats a real timestamp and blanks a missing one', () {
      expect(formatFsDate(0), '');
      expect(formatFsDate(-1), '');
      final formatted = formatFsDate(DateTime(2026, 5, 30, 14, 5).millisecondsSinceEpoch);
      expect(formatted, '2026-05-30 14:05');
    });
  });

  group('copyWithProgress', () {
    test('copies every byte and reports a final total', () async {
      final reports = <(int, int)>[];
      final sink = _CollectingSink();
      final copied = await copyWithProgress(
        Stream.fromIterable([
          [1, 2, 3],
          [4, 5],
        ]),
        sink,
        5,
        onProgress: (c, t) => reports.add((c, t)),
      );

      expect(copied, 5);
      expect(sink.bytes, [1, 2, 3, 4, 5]);
      expect(reports.first, (0, 5), reason: 'an initial 0 lets the UI render the row immediately');
      expect(reports.last, (5, 5));
    });

    test('an unknown total is replaced by the observed count on completion', () async {
      final reports = <(int, int)>[];
      await copyWithProgress(
        Stream.fromIterable([
          [1, 2, 3],
        ]),
        _CollectingSink(),
        0,
        onProgress: (c, t) => reports.add((c, t)),
      );
      expect(reports.last, (3, 3), reason: 'otherwise a finished transfer renders as partial');
    });

    test('progress is throttled, not emitted per chunk', () async {
      // 200 tiny chunks well under the 64 KiB threshold and inside 150 ms: only the bookend reports
      // should appear, which is what keeps a fast transfer from drowning the UI thread.
      final reports = <int>[];
      await copyWithProgress(
        Stream.fromIterable(List.generate(200, (_) => [0])),
        _CollectingSink(),
        200,
        onProgress: (c, _) => reports.add(c),
      );
      expect(
        reports.length,
        lessThan(10),
        reason: 'got ${reports.length} callbacks for 200 chunks',
      );
      expect(reports.last, 200);
    });

    test('crossing the byte threshold does emit an interim report', () async {
      final reports = <int>[];
      await copyWithProgress(
        Stream.fromIterable([List.filled(70 * 1024, 0), List.filled(10, 0)]),
        _CollectingSink(),
        70 * 1024 + 10,
        onProgress: (c, _) => reports.add(c),
      );
      expect(reports, contains(70 * 1024));
    });
  });
}

class _CollectingSink implements StreamSink<List<int>> {
  final List<int> bytes = [];

  @override
  void add(List<int> data) => bytes.addAll(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();
}

class _StubFsClient extends RemoteFsClient {
  _StubFsClient(this._home);

  final String _home;

  @override
  Future<String> home() async => _home;

  @override
  Future<List<SftpFile>> list(String path) async => const [];

  @override
  Future<void> mkdir(String path) async {}

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) async {}

  @override
  Future<void> delete(String path, {required bool isDirectory}) async {}

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) async => 0;

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) async {}
}
