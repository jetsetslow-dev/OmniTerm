/// Platform-neutral latest-operation-wins coordination.
///
/// Ported from `ui/OperationGeneration.kt`. Long-running UI work often cannot be cancelled once it
/// has crossed into a platform API. A generation token still prevents an older completion from
/// replacing the result of a newer user request.
///
/// The Kotlin marked every method `@Synchronized` and gave `publishIfCurrent` an explicit
/// `synchronized` block to close the check-then-publish race. **Dart needs neither.** An isolate is
/// single-threaded and only yields at an `await`; [publishIfCurrent] takes a synchronous callback
/// and performs no `await` between the check and the publish, so the race it guarded against cannot
/// occur. Passing an `async` callback would reintroduce it — hence the synchronous signature.
library;

class OperationGeneration<K> {
  final Map<K, int> _generations = {};

  /// Claims the next generation for each key, returning the tokens the caller must carry through to
  /// its completion handler.
  Map<K, int> begin(Iterable<K> keys) {
    final issued = <K, int>{};
    for (final key in keys) {
      final next = (_generations[key] ?? 0) + 1;
      _generations[key] = next;
      issued[key] = next;
    }
    return issued;
  }

  bool isCurrent(K key, int generation) => _generations[key] == generation;

  /// Publishes only when [generation] is still the newest for [key], returning whether it ran.
  ///
  /// [publish] is deliberately synchronous: see the note on this library.
  bool publishIfCurrent(K key, int generation, void Function() publish) {
    if (_generations[key] != generation) return false;
    publish();
    return true;
  }

  void forget(Iterable<K> keys) {
    for (final key in keys) {
      _generations.remove(key);
    }
  }
}
