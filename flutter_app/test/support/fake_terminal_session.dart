import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

/// A [TerminalSession] driven from the test rather than by a real SSH channel.
///
/// Deliberately models the two endings separately — [endByRemoteExit] and [dropConnection] — because
/// the app's whole close policy hangs on telling them apart, and a fake that collapses them into one
/// "closed" flag would let a regression through unnoticed.
class FakeTerminalSession implements TerminalSession {
  final _output = StreamController<Uint8List>();

  /// Everything written to the remote, in order.
  final List<Uint8List> writes = [];

  /// Every `(cols, rows)` the session asked the remote for.
  final List<(int, int)> resizes = [];

  /// Completes each resize only when the test says so, so overlapping resizes can be observed.
  Completer<void>? gateResize;

  bool closeCalled = false;
  Object? writeFailure;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  final ValueNotifier<bool> closed = ValueNotifier(false);

  @override
  final ValueNotifier<int?> exitStatus = ValueNotifier(null);

  @override
  final ValueNotifier<bool> remoteExited = ValueNotifier(false);

  @override
  Future<void> write(Uint8List bytes) async {
    final failure = writeFailure;
    if (failure != null) throw failure;
    writes.add(bytes);
  }

  @override
  Future<void> resize(int cols, int rows) async {
    resizes.add((cols, rows));
    final gate = gateResize;
    if (gate != null) await gate.future;
  }

  @override
  void close() {
    closeCalled = true;
    closed.value = true;
    if (!_output.isClosed) _output.close();
  }

  /// Deliver remote output.
  void emit(String text) => _output.add(Uint8List.fromList(text.codeUnits));

  /// The remote shell ran to completion and the server sent a genuine channel EOF.
  Future<void> endByRemoteExit({int status = 0}) async {
    remoteExited.value = true;
    exitStatus.value = status;
    await _output.close();
  }

  /// The transport went away: the stream ends with no EOF and no status, exactly as a dropped
  /// socket leaves it.
  Future<void> dropConnection() async => _output.close();

  Future<void> dispose() async {
    if (!_output.isClosed) await _output.close();
  }
}
