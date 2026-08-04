import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/shares/platform_smb_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const endpoint = SmbEndpoint(
    host: 'nas.local',
    port: 445,
    shareName: 'media',
    username: 'sam',
    password: 'hunter2',
  );

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> handlers;
  late MethodChannel channel;

  void respond(String method, Object? Function(MethodCall) handler) =>
      handlers[method] = handler;

  setUp(() {
    calls = [];
    handlers = {};
    channel = const MethodChannel(PlatformSmbClient.methodChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final handler = handlers[call.method];
      if (handler != null) return handler(call);
      return switch (call.method) {
        'connect' => 'session-1',
        'list' => <Object?>[],
        _ => true,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<Object?, Object?> argsOf(String method) =>
      calls.firstWhere((c) => c.method == method).arguments as Map<Object?, Object?>;

  group('connecting', () {
    test('the share is opened once and reused', () async {
      // Negotiate, session setup and tree connect are several round-trips; reconnecting per call
      // would make browsing a directory tree feel broken on any real network.
      final client = PlatformSmbClient(endpoint);

      await client.list('/');
      await client.list('/movies');
      await client.mkdir('/movies/new');

      expect(calls.where((c) => c.method == 'connect'), hasLength(1));
      expect(argsOf('list')['session'], 'session-1');
    });

    test('the endpoint is passed through in full', () async {
      final client = PlatformSmbClient(endpoint);
      await client.list('/');

      final args = argsOf('connect');
      expect(args['host'], 'nas.local');
      expect(args['share'], 'media');
      expect(args['username'], 'sam');
      expect(args['anonymous'], false);
      client.close();
    });

    test('a missing platform implementation says so, and names an alternative', () async {
      // Convention 4: a share that fails on first tap with a channel error tells the user nothing.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final client = PlatformSmbClient(endpoint);

      expect(await client.isSupported(), isFalse);
      await expectLater(
        client.list('/'),
        throwsA(isA<SmbException>().having((e) => e.message, 'message', contains('SFTP'))),
      );
    });
  });

  group('listing', () {
    test('rows become files, with directories sized zero', () async {
      // A directory's "size" on SMB is an implementation detail, not a byte count.
      respond('list', (_) => [
            {'name': 'movies', 'isDirectory': true, 'size': 4096, 'modTimeSeconds': 1700000000},
            {'name': 'clip.mkv', 'isDirectory': false, 'size': 12345, 'modTimeSeconds': 1700000000},
          ]);
      final client = PlatformSmbClient(endpoint);

      final files = await client.list('/');

      expect(files.map((f) => f.name), ['movies', 'clip.mkv']);
      expect(files.first.isDirectory, isTrue);
      expect(files.first.size, 0);
      expect(files.last.size, 12345);
      expect(files.first.modDate, isNotEmpty);
      client.close();
    });

    test('a malformed row does not take the listing down', () async {
      respond('list', (_) => [
            'not a row',
            {'name': 'ok.txt', 'isDirectory': false, 'size': 1, 'modTimeSeconds': 0},
          ]);
      final client = PlatformSmbClient(endpoint);

      expect((await client.list('/')).single.name, 'ok.txt');
      client.close();
    });
  });

  group('errors', () {
    test('a protocol error keeps the warm connection', () async {
      // Access denied is not a reason to tear down a working session; the next call would then pay
      // for a whole reconnect over a permissions problem.
      respond('delete', (_) => throw PlatformException(code: 'smb', message: 'Access denied'));
      final client = PlatformSmbClient(endpoint);
      await client.list('/');

      await expectLater(
        client.delete('/locked', isDirectory: false),
        throwsA(isA<SmbException>().having((e) => e.message, 'message', 'Access denied')),
      );

      await client.list('/');
      expect(calls.where((c) => c.method == 'connect'), hasLength(1));
      client.close();
    });

    test('a transport error drops the session so the next call reconnects', () async {
      var failNext = true;
      respond('list', (_) {
        if (failNext) {
          failNext = false;
          throw PlatformException(code: 'transport', message: 'Connection reset');
        }
        return <Object?>[];
      });
      final client = PlatformSmbClient(endpoint);

      await expectLater(client.list('/'), throwsA(isA<SmbException>()));
      await client.list('/');

      expect(calls.where((c) => c.method == 'connect'), hasLength(2));
      client.close();
    });
  });

  group('uploads', () {
    test('the stream is written in order and closed', () async {
      final client = PlatformSmbClient(endpoint);

      await client.uploadStream(
        '/movies/new.mkv',
        Stream.fromIterable([
          [1, 2, 3],
          [4, 5],
        ]),
        5,
      );

      final chunks = calls.where((c) => c.method == 'uploadChunk').toList();
      expect(chunks, hasLength(2));
      expect((chunks.first.arguments as Map)['bytes'], Uint8List.fromList([1, 2, 3]));
      expect(calls.map((c) => c.method), containsAllInOrder(['uploadBegin', 'uploadChunk', 'uploadEnd']));
      client.close();
    });

    test('progress is reported against the declared total', () async {
      final client = PlatformSmbClient(endpoint);
      final progress = <(int, int)>[];

      await client.uploadStream(
        '/f',
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        4,
        onProgress: (copied, total) => progress.add((copied, total)),
      );

      expect(progress, [(2, 4), (4, 4)]);
      client.close();
    });

    test('a failed upload aborts the handle rather than leaving it open', () async {
      // An abandoned handle keeps a truncated file locked on the share until the session drops.
      respond('uploadChunk', (_) => throw PlatformException(code: 'smb', message: 'Disk full'));
      final client = PlatformSmbClient(endpoint);

      await expectLater(
        client.uploadStream('/f', Stream.fromIterable([[1]]), 1),
        throwsA(isA<SmbException>()),
      );

      expect(calls.any((c) => c.method == 'uploadAbort'), isTrue);
      client.close();
    });
  });

  group('closing', () {
    test('disconnects the native session', () async {
      final client = PlatformSmbClient(endpoint);
      await client.list('/');

      client.close();
      await Future<void>.delayed(Duration.zero);

      expect(argsOf('disconnect')['session'], 'session-1');
    });

    test('a closed client refuses further work rather than reconnecting', () async {
      final client = PlatformSmbClient(endpoint);
      await client.list('/');
      client.close();

      await expectLater(client.list('/'), throwsA(isA<SmbException>()));
      expect(calls.where((c) => c.method == 'connect'), hasLength(1));
    });

    test('closing twice is harmless', () async {
      final client = PlatformSmbClient(endpoint)..close();
      client.close();
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'disconnect'), isEmpty);
    });
  });

  test('the endpoint label carries no secret', () {
    // It goes into error text and logs.
    expect(endpoint.label, r'\\nas.local\media');
    expect(endpoint.label, isNot(contains('hunter2')));
  });
}
