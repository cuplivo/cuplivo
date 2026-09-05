/// Coalesced queue for pending tool-extent invalidations.
///
/// A tree-height change lands while the list controller is detached (cold
/// window load still in flight, or a controller swap during rebuild) or
/// locked by the layout pass. The queue holds the message ids until the
/// controller is attached and unlocked, so a dropped event never leaves a
/// stale extent behind.
///
/// The state machine is deliberately small and owns no timers: the
/// [MessageListView] schedules the retries, this class answers whether a
/// flush can drain now.
final class ToolExtentInvalidationQueue {
  final Set<String> _pending = <String>{};

  /// Whether any invalidation is queued.
  bool get hasPending => _pending.isNotEmpty;

  /// A snapshot of the queued ids, newest-first order preserved as queued.
  List<String> get pendingIds => List<String>.unmodifiable(_pending);

  /// Queues [messageId]; returns false when it was already queued, so the
  /// caller can skip a redundant flush.
  bool enqueue(String messageId) => _pending.add(messageId);

  /// Drains the queue when [isAttached] is true and [isLocked] is false.
  ///
  /// Returns the ids to invalidate and whether the caller must poll again:
  /// [reschedule] is true while the controller stays detached or locked and
  /// work is still pending. The caller owns the polling cadence.
  ({List<String> ids, bool reschedule}) takeForFlush({
    required bool isAttached,
    required bool isLocked,
  }) {
    if (isAttached && !isLocked) {
      final ids = _pending.toList();
      _pending.clear();
      return (ids: ids, reschedule: false);
    }
    return (ids: const <String>[], reschedule: _pending.isNotEmpty);
  }

  /// Drops everything queued (widget teardown).
  void clear() => _pending.clear();
}
