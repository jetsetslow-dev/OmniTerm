import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:omniterm/data/shares/ftp_remote_fs_client.dart';

void main() {
  test('FTP uses structured MLSD only when the server advertises it', () {
    expect(
      ftpListCommandForFeatures('211-Features:\n MLST type*;size*;modify*;\n211 End'),
      ListCommand.mlsd,
    );
    expect(ftpListCommandForFeatures('211-Features:\n MLSD\n211 End'), ListCommand.mlsd);
  });

  test('FTP falls back to portable LIST when MLSD is unavailable', () {
    expect(
      ftpListCommandForFeatures('211-Features:\n EPSV\n MDTM\n SIZE\n UTF8\n211 End'),
      ListCommand.list,
    );
    expect(ftpListCommandForFeatures('500 Unknown command.'), ListCommand.list);
  });

  /// How the client holds connections, matching the Kotlin app's `FtpFsClient`, against a small
  /// in-process FTP server so ftpconnect's real command sequence is exercised.
  group('connections', () {
    late _FtpServer server;
    late FtpRemoteFsClient client;

    Future<void> start({String typeReply = '200 Type set to I'}) async {
      server = await _FtpServer.start(typeReply: typeReply);
      client = FtpRemoteFsClient(
        host: '127.0.0.1',
        port: server.port,
        username: 'u',
        password: 'p',
        // A short reply timeout so a dead connection is noticed quickly in the test.
        connector: () =>
            FTPConnect('127.0.0.1', port: server.port, user: 'u', pass: 'p', timeout: 2),
      );
    }

    tearDown(() async {
      client.close();
      await server.stop();
    });

    test('every connection switches to binary right after login', () async {
      // ASCII mode lets a server rewrite line endings, corrupting every binary file.
      await start();
      await client.home();
      final commands = server.commandsOn(0);
      expect(commands.indexOf('TYPE I'), commands.indexOf('PASS p') + 1);
    });

    test('a server that refuses binary mode is not used', () async {
      await start(typeReply: '504 Command not implemented for that parameter');
      await expectLater(client.home(), throwsA(isA<FileSystemException>()));
      expect(server.commandsOn(0), isNot(contains('PWD')));
    });

    test('a dropped control connection is redialled instead of failing forever', () async {
      // Servers drop idle sessions (vsftpd after five minutes). The connection used to be marked
      // connected for good, so every later action failed until the share was reopened.
      await start();
      await client.home();
      await server.dropAll();

      expect(await client.home(), '/');
      expect(server.connections, 2);
      expect(server.commandsOn(1), contains('TYPE I'));
    });

    test('a command the server refuses is reported, not retried', () async {
      await start();
      await expectLater(client.mkdir('/denied'), throwsA(isA<FileSystemException>()));
      expect(server.allCommands.where((c) => c == 'MKD /denied'), hasLength(1));
    });

    test('a download runs on its own connection, which is then closed', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final temp = Directory.systemTemp.createTempSync('omniterm-ftp-test-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => temp.path,
      );
      await start();
      await client.home();

      final received = <int>[];
      final sink = StreamController<List<int>>();
      final drained = sink.stream.listen(received.addAll).asFuture<void>();
      await client.downloadTo('/file.bin', sink.sink);
      await sink.close();
      await drained;

      expect(received, [1, 2, 3]);
      expect(server.connections, 2, reason: 'a listing must not wait behind a transfer');
      expect(server.commandsOn(1), containsAllInOrder(['TYPE I', 'RETR /file.bin']));
      await server.settled();
      expect(server.commandsOn(1).last, 'QUIT', reason: 'the transfer connection is closed');
      expect(server.commandsOn(0), isNot(contains('QUIT')));
    });
  });
}

/// Just enough of an FTP server for the connection tests: login, TYPE, FEAT, NOOP, PWD, CWD, MKD
/// (always refused), SIZE, PASV and RETR of a three-byte file.
class _FtpServer {
  _FtpServer._(this._listener, this.typeReply);

  static Future<_FtpServer> start({required String typeReply}) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _FtpServer._(listener, typeReply);
    listener.listen(server._serve);
    return server;
  }

  final ServerSocket _listener;
  final String typeReply;
  final List<Socket> _sockets = [];
  final List<List<String>> _commands = [];
  final List<Future<void>> _pending = [];

  int get port => _listener.port;
  int get connections => _commands.length;
  List<String> commandsOn(int connection) => _commands[connection];
  Iterable<String> get allCommands => _commands.expand((c) => c);

  void _serve(Socket socket) {
    _sockets.add(socket);
    final commands = <String>[];
    _commands.add(commands);
    ServerSocket? data;
    socket.write('220 ready\r\n');
    var queue = Future<void>.value();
    socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      commands.add(line);
      queue = queue.then((_) async {
        final verb = line.split(' ').first.toUpperCase();
        switch (verb) {
          case 'USER':
            socket.write('331 password please\r\n');
          case 'PASS':
            socket.write('230 logged in\r\n');
          case 'TYPE':
            socket.write('$typeReply\r\n');
          case 'FEAT':
            socket.write('211 End\r\n');
          case 'NOOP':
            socket.write('200 ok\r\n');
          case 'PWD':
            socket.write('257 "/"\r\n');
          case 'CWD':
            socket.write('250 ok\r\n');
          case 'MKD':
            socket.write('550 denied\r\n');
          case 'SIZE':
            socket.write('213 3\r\n');
          case 'PASV':
            data = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
            final p = data!.port;
            socket.write('227 Entering Passive Mode (127,0,0,1,${p ~/ 256},${p % 256})\r\n');
          case 'RETR':
            final transfer = await data!.first;
            socket.write('150 opening\r\n');
            await Future<void>.delayed(const Duration(milliseconds: 400));
            transfer.add([1, 2, 3]);
            await transfer.close();
            await data!.close();
            await Future<void>.delayed(const Duration(milliseconds: 400));
            socket.write('226 done\r\n');
          case 'QUIT':
            socket.write('221 bye\r\n');
            await socket.close();
          default:
            socket.write('502 not implemented\r\n');
        }
      });
      _pending.add(queue);
    }, onError: (Object _) {});
  }

  /// Waits for every reply already queued, such as a QUIT sent while the test moved on.
  Future<void> settled() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await Future.wait(_pending);
  }

  /// Drops every control connection, as a server does to an idle session.
  Future<void> dropAll() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  Future<void> stop() async {
    await dropAll();
    await _listener.close();
  }
}
