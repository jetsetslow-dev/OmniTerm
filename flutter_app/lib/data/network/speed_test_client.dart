import 'dart:async';

import 'package:dio/dio.dart';

class SpeedTestSample {
  const SpeedTestSample({required this.bytes, required this.mbps});

  final int bytes;
  final double mbps;
}

class SpeedTestResult {
  const SpeedTestResult({required this.bytes, required this.mbps, required this.latency});

  final int bytes;
  final double mbps;
  final Duration latency;
}

abstract interface class SpeedTestOperation {
  Future<SpeedTestResult> get result;
  void cancel();
}

abstract interface class SpeedTestClient {
  SpeedTestOperation download(
    String url, {
    required void Function(SpeedTestSample sample) onProgress,
    Duration maximumDuration = const Duration(seconds: 15),
  });
}

/// Streams a test download without retaining its payload in memory.
class DioSpeedTestClient implements SpeedTestClient {
  DioSpeedTestClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  SpeedTestOperation download(
    String url, {
    required void Function(SpeedTestSample sample) onProgress,
    Duration maximumDuration = const Duration(seconds: 15),
  }) {
    final token = CancelToken();
    final future = _download(
      url,
      token: token,
      onProgress: onProgress,
      maximumDuration: maximumDuration,
    );
    return _DioSpeedTestOperation(token, future);
  }

  Future<SpeedTestResult> _download(
    String url, {
    required CancelToken token,
    required void Function(SpeedTestSample sample) onProgress,
    required Duration maximumDuration,
  }) async {
    final requestStarted = Stopwatch()..start();
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        validateStatus: (status) => status != null && status >= 200 && status < 300,
        headers: const {'User-Agent': 'OmniTerm-SpeedTest'},
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final latency = requestStarted.elapsed;
    final downloadStarted = Stopwatch()..start();
    var bytes = 0;
    var lastEmit = Duration.zero;

    await for (final chunk in response.data!.stream.timeout(const Duration(seconds: 8))) {
      bytes += chunk.length;
      final elapsed = downloadStarted.elapsed;
      if (elapsed - lastEmit >= const Duration(milliseconds: 100)) {
        lastEmit = elapsed;
        onProgress(_sample(bytes, elapsed));
      }
      if (elapsed >= maximumDuration) {
        token.cancel('Speed-test duration reached');
        break;
      }
    }

    final result = _sample(bytes, downloadStarted.elapsed);
    onProgress(result);
    return SpeedTestResult(bytes: result.bytes, mbps: result.mbps, latency: latency);
  }

  static SpeedTestSample _sample(int bytes, Duration elapsed) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    return SpeedTestSample(bytes: bytes, mbps: seconds <= 0 ? 0 : bytes * 8 / 1000000 / seconds);
  }
}

class _DioSpeedTestOperation implements SpeedTestOperation {
  _DioSpeedTestOperation(this._token, this.result);

  final CancelToken _token;

  @override
  final Future<SpeedTestResult> result;

  @override
  void cancel() => _token.cancel('Speed test stopped');
}
