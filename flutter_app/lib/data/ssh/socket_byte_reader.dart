import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Why a handshake read cannot go on.
enum HandshakeStall { failed, closed, timedOut }

/// Reads a precise number of bytes from a socket during a handshake, then hands the live stream on
/// untouched. Used by the outgoing proxy handshakes and by the SOCKS server of a dynamic forward.
///
/// A single subscription is taken for the whole handshake and any surplus is kept, because the
/// peer's reply and the first bytes of the tunnelled stream can arrive in one packet: a reader that
/// over-read and discarded would eat the start of the stream.
class SocketByteReader {
  /// [stalled] words the exception for each way a read can stop; `error` is the socket's error
  /// for [HandshakeStall.failed] and null otherwise.
  SocketByteReader(Socket socket, this._stalled) {
    _subscription = socket.listen(
      _buffer.add,
      onError: (Object e) => _error ??= e,
      onDone: () => _done = true,
      cancelOnError: false,
    );
  }

  final Exception Function(HandshakeStall stall, Object? error) _stalled;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: true);
  Object? _error;
  bool _done = false;
  bool _released = false;

  /// What has arrived and not been read yet, left in place.
  Uint8List peek() {
    final all = _buffer.takeBytes();
    _buffer.add(all);
    return all;
  }

  /// Throws when nothing more can arrive in time: the socket failed or closed, or [deadline] passed.
  void throwIfStalled(DateTime deadline) {
    if (_error != null) throw _stalled(HandshakeStall.failed, _error);
    if (_done) throw _stalled(HandshakeStall.closed, null);
    if (DateTime.now().isAfter(deadline)) throw _stalled(HandshakeStall.timedOut, null);
  }

  Future<Uint8List> read(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      throwIfStalled(deadline);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final all = _buffer.takeBytes();
    _buffer.add(all.sublist(count));
    return Uint8List.sublistView(all, 0, count);
  }

  /// Hands the live connection on: whatever arrived after the handshake is replayed first, then
  /// everything the socket produces from here.
  ///
  /// The subscription is *kept*, not cancelled — `Socket` is single-subscription, so cancelling
  /// would leave the next reader with a stream it cannot listen to.
  Stream<Uint8List> release() {
    if (_released) throw StateError('Socket reader already released.');
    _released = true;
    final controller = StreamController<Uint8List>();
    final surplus = _buffer.takeBytes();
    if (surplus.isNotEmpty) controller.add(surplus);
    if (_error != null) {
      controller.addError(_error!);
    } else if (_done) {
      unawaited(controller.close());
    }
    _subscription
      ..onData(controller.add)
      ..onError(controller.addError)
      ..onDone(controller.close);
    return controller.stream;
  }

  /// Stops reading a socket whose handshake was abandoned. Nothing to do once it was released.
  Future<void> cancel() => _released ? Future.value() : _subscription.cancel();
}
