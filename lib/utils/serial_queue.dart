import 'dart:async';

/// Runs tasks one at a time per key, in submission order.
///
/// The point is a read-then-write sequence: when a caller rebuilds a whole value
/// from a snapshot and writes it back, two concurrent runs both build from the
/// same pre-image and the second write erases the first. Chaining by key makes
/// the second run's read happen after the first run's write.
///
/// A failing task does not poison the chain: the next task still runs, and the
/// failure is reported to the returned future of *that* task only.
final class SerialQueue {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// Queues [task] behind everything already queued for [key].
  ///
  /// The returned future completes when [task] completes, and carries its error.
  Future<void> run(String key, Future<void> Function() task) {
    final previous = _tails[key] ?? Future<void>.value();
    final next = previous.then<void>((_) => task());
    // The tail swallows failures so one bad write cannot block the queue; the
    // caller still sees the error through `next`.
    final tail = next.catchError((Object _) {});
    _tails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return next;
  }
}
