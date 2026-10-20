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

  String _url(String path, {bool collection = false}) =>
      '$_origin${webDavResourcePath(path, collection: collection)}';

  void _check(Response<dynamic> response, Iterable<int> accepted, String action, String path) {
    if (!accepted.contains(response.statusCode)) {
      throw FileSystemException('$action failed with HTTP ${response.statusCode}', path);
    }
  }

  @override
  Future<String> home() async => '/';

  @override
  Future<List<SftpFile>> list(String path) async {
    final response = await _dio.request<String>(
      // A WebDAV collection has a canonical trailing slash. Apache and many managed servers
      // redirect `/folder` to `/folder/`; Dio does not replay a PROPFIND through that redirect, and
      // even clients that do may turn the custom method into GET. Address the collection directly.
      _url(path, collection: true),
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
      Uri.parse(_url(path, collection: true)).path,
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
      final href = webDavHrefToPath(text('href')).replaceFirst(RegExp(r'/+$'), '');
      if (href == wantedPath || href.isEmpty) continue;
      final name = text('displayname').isNotEmpty ? text('displayname') : href.split('/').last;
      final isDirectory = item.descendants.whereType<XmlElement>().any(
        (node) => node.name.local == 'collection',
      );
      final modified = parseWebDavDate(text('getlastmodified'));
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
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) async {
    final response = await _dio.request<void>(
      _url(oldPath),
      options: Options(method: 'MOVE', headers: {'Destination': _url(newPath), 'Overwrite': 'F'}),
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
    final total = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '') ?? -1;
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
        throw FileSystemException('WebDAV file is larger than the editor limit', path);
      }
      bytes.addAll(chunk);
    });
    final completed = subscription.asFuture<void>();
    await downloadTo(path, controller.sink);
    await controller.close();
    await completed;
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

/// Turns a `<D:href>` into a server-relative path.
///
/// hrefs are legal either way: RFC 4918 allows an absolute URL or an absolute path, and real servers
/// send both. This port compared the raw href against the requested path, so against a server
/// answering with absolute URLs the collection never matched itself and **appeared as an entry
/// inside its own listing**. Compose strips the scheme and authority first (`hrefToPath`,
/// `data/shares/WebDavFsClient.kt:203`); this does the same.
String webDavHrefToPath(String href) {
  var raw = href.trim();
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final afterScheme = raw.substring(raw.indexOf('://') + 3);
    final slash = afterScheme.indexOf('/');
    raw = slash >= 0 ? afterScheme.substring(slash) : '/';
  }
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    // A badly encoded href is still better used verbatim than dropped. `decodeComponent` throws
    // ArgumentError rather than FormatException for a stray `%`, so this catches both.
    return raw;
  }
}

const _httpDateMonths = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

final _rfc1123 = RegExp(
  r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
);

/// Parses a WebDAV `getlastmodified`, which is an HTTP-date, not an ISO 8601 timestamp.
///
/// `DateTime.tryParse` returns **null** for `Tue, 11 Aug 2026 10:00:00 GMT` — the format RFC 4918
/// requires for this property. This port used `tryParse` alone, so every file on every WebDAV share
/// came back with a modified time of zero: no date in the listing, and sorting by date silently
/// ranked everything equal. Compose parses it with an explicit RFC 1123 format
/// (`data/shares/WebDavFsClient.kt:215`).
///
/// ISO is still accepted afterwards, because a few servers send it despite the spec.
DateTime? parseWebDavDate(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final match = _rfc1123.firstMatch(text);
  if (match != null) {
    final month = _httpDateMonths[match.group(2)!.toLowerCase()];
    if (month != null) {
      return DateTime.utc(
        int.parse(match.group(3)!),
        month,
        int.parse(match.group(1)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6)!),
      );
    }
  }
  return DateTime.tryParse(text);
}

/// Encodes a WebDAV resource path, preserving the canonical slash for a collection request.
String webDavResourcePath(String path, {bool collection = false}) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty).map(Uri.encodeComponent);
  final encoded = '/${segments.join('/')}';
  return collection && encoded != '/' ? '$encoded/' : encoded;
}
