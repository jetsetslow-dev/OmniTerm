/// Monotonic stop/start ownership for one tunnel id, ported from `TunnelGeneration` in
/// `data/ssh/SshTunnelManager.kt`.
///
/// A tunnel start awaits a connection, and `stop()` deliberately does **not** take the per-tunnel
/// lock — otherwise stopping would block behind a start that is hung dialling an unreachable host.
/// That means a stop can land while a start is mid-flight, and the started tunnel must then be
/// discarded rather than published. This token is how that is detected.
class TunnelGeneration {
  int _value = 0;

  int snapshot() => _value;

  /// Marks every in-flight start for this tunnel as stale.
  int invalidate() => ++_value;

  /// Publishes only if no [invalidate] has happened since [expected] was taken.
  ///
  /// The Kotlin validated on **both** sides of `publish` so a stop landing in the tiny
  /// check-to-publication window was rolled back rather than leaving a tunnel alive after `stop()`
  /// returned. On a single-threaded isolate that second check cannot currently fail, because
  /// [publish] is synchronous and nothing can interleave with it — but it is kept, and kept cheap,
  /// so that adding an `await` inside a publish callback later cannot silently reintroduce the leak
  /// the Kotlin was guarding against.
  bool publishIfCurrent({
    required int expected,
    required void Function() publish,
    required void Function() rollback,
  }) {
    if (_value != expected) return false;
    publish();
    if (_value == expected) return true;
    rollback();
    return false;
  }
}
