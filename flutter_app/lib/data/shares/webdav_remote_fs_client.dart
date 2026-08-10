import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../remote_models.dart';
import 'remote_fs_client.dart';

/// Standards-based WebDAV client using PROPFIND/MKCOL/MOVE/DELETE and streamed GET/PUT.
class WebDavRemoteFsClient extends RemoteFsClient {
  WebDavRemoteFsClient({
    required String host,
    required int port,
    required bool useHttps,
    required String username,
    required String password,
    Dio? dio,
  }) : _origin = '${useHttps ? 'https' : 'http'}://$host:$port',
       _dio = dio ?? Dio() {
    if (username.isNotEmpty || password.isNotEmpty) {
      _dio.options.headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    }
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
  }

  final String _origin;
  final Dio _dio;
  CancelToken _cancel = CancelToken();

  String _url(String path) {
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent);
    return '$_origin/${segments.join('/')}';
  }

  void _check(
    Response<dynamic> response,
    Iterable<int> accepted,
    String action,
    String path,
  ) {
    if (!accepted.contains(response.statusCode)) {
      throw FileSystemException(
        '$action failed with HTTP ${response.statusCode}',
        path,
      );
    }
  }

  @override
  Future<String> home() async => '/';

  @override
  Future<List<SftpFile>> list(String path) async {
    final response = await _dio.request<String>(
      _url(path),
      options: Options(
        method: 'PROPFIND',
        headers: const {'Depth': '1'},
        responseType: ResponseType.plain,
      ),
      data:
          '''<?xml version="1.0"?><propfind xmlns="DAV:"><prop><displayname/><resourcetype/><getcontentlength/><getlastmodified/></prop></propfind>''',
      cancelToken: _cancel,
    );
    _check(response, const [207], 'WebDAV listing', path);
    final document = XmlDocument.parse(response.data ?? '');
    final wantedPath = Uri.decodeComponent(
      Uri.parse(_url(path)).path,
    ).replaceFirst(RegExp(r'/+$'), '');
    final files = <SftpFile>[];
    for (final item in document.descendants.whereType<XmlElement>().where(
      (node) => node.name.local == 'response',
    )) {
      String text(String name) =>
          item.descendants
              .whereType<XmlElement>()
              .where((node) => node.name.local == name)
              .map((node) => node.innerText.trim())
              .firstOrNull ??
          '';
      final href = Uri.decodeComponent(
        text('href'),
      ).replaceFirst(RegExp(r'/+$'), '');
      if (href == wantedPath || href.isEmpty) continue;
      final name = text('displayname').isNotEmpty
          ? text('displayname')
          : href.split('/').last;
      final isDirectory = item.descendants.whereType<XmlElement>().any(
        (node) => node.name.local == 'collection',
      );
      final modified = DateTime.tryParse(text('getlastmodified'));
      files.add(
        SftpFile(
          name: name,
          isDirectory: isDirectory,
          size: int.tryParse(text('getcontentlength')) ?? 0,
          modDate: formatFsDate(modified?.millisecondsSinceEpoch ?? 0),
          modTimeSeconds: (modified?.millisecondsSinceEpoch ?? 0) ~/ 1000,
        ),
      );
    }
    return files;
  }

  @override
  Future<void> mkdir(String path) async {
    final response = await _dio.request<void>(
      _url(path),
      options: Options(method: 'MKCOL'),
      cancelToken: _cancel,
    );
    _check(response, const [201, 204], 'WebDAV create directory', path);
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool isDirectory = false,
  }) async {
    final response = await _dio.request<void>(
      _url(oldPath),
      options: Options(
        method: 'MOVE',
        headers: {'Destination': _url(newPath), 'Overwrite': 'F'},
      ),
      cancelToken: _cancel,
    );
    _check(response, const [201, 204], 'WebDAV move', oldPath);
  }

  @override
  Future<void> delete(String path, {required bool isDirectory}) async {
    final response = await _dio.delete<void>(_url(path), cancelToken: _cancel);
    _check(response, const [200, 202, 204], 'WebDAV delete', path);
  }

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) async {
    final response = await _dio.get<ResponseBody>(
      _url(path),
      options: Options(responseType: ResponseType.stream),
      cancelToken: _cancel,
    );
    _check(response, const [200, 206], 'WebDAV download', path);
    final total =
        int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ) ??
        -1;
    var copied = 0;
    await for (final chunk in response.data!.stream) {
      copied += chunk.length;
      output.add(chunk);
      onProgress?.call(copied, total);
    }
    return copied;
  }

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) async {
    var copied = 0;
    final measured = input.map((chunk) {
      copied += chunk.length;
      onProgress?.call(copied, totalBytes);
      return Uint8List.fromList(chunk);
    });
    final response = await _dio.put<void>(
      _url(path),
      data: measured,
      options: Options(headers: {Headers.contentLengthHeader: totalBytes}),
      cancelToken: _cancel,
    );
    _check(response, const [200, 201, 204], 'WebDAV upload', path);
  }

  @override
  bool get supportsTextEditing => true;

  @override
  Future<String> readText(String path, {int maxBytes = 512 * 1024}) async {
    final bytes = <int>[];
    final controller = StreamController<List<int>>();
    final subscription = controller.stream.listen((chunk) {
      if (bytes.length + chunk.length > maxBytes) {
        throw FileSystemException(
          'WebDAV file is larger than the editor limit',
          path,
        );
      }
      bytes.addAll(chunk);
    });
    await downloadTo(path, controller.sink);
    await controller.close();
    await subscription.asFuture<void>();
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<int> writeText(String path, String content) async {
    final bytes = utf8.encode(content);
    await uploadStream(path, Stream.value(bytes), bytes.length);
    return bytes.length;
  }

  @override
  void cancelActiveTransfers() {
    _cancel.cancel('Transfer cancelled');
    _cancel = CancelToken();
  }

  @override
  void close() {
    _cancel.cancel('Connection closed');
    _dio.close(force: true);
  }
}
