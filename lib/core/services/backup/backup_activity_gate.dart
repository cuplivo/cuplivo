import 'dart:async';

/// Cross-feature exclusive gate for backup-family operations.
///
/// Guarantees no two gated operations run at the same time: a call that
/// arrives while the gate is held is queued FIFO and resumes only after the
/// in-flight operation has fully ended.
///
/// Reentrancy: nested calls along the same async chain (e.g.
/// `backupToWebDav` -> `prepareBackupFile`, or an auto snapshot holding the
/// gate while its own export re-enters it) are detected via a zone-local
/// marker and proceed immediately without waiting, so a strict mutex would
/// not deadlock. [active] also reports nested depth.
final class BackupActivityGate {
  BackupActivityGate._();

  static int _depth = 0;
  static final List<Completer<void>> _waiters = [];
  static final Object _reentryKey = Object();

  /// True while any gated backup/restore/export operation is in flight.
  static bool get active => _depth > 0;

  /// Runs [action] while holding the gate, as a FIFO exclusive permit.
  ///
  /// Re-entrant along the same chain: if the caller's zone already holds the
  /// gate, [action] runs right away.
  static Future<T> scoped<T>(Future<T> Function() action) {
    if (Zone.current[_reentryKey] != null) {
      _depth++;
      return () async {
        try {
          return await action();
        } finally {
          _release();
        }
      }();
    }
    if (_depth == 0) {
      // Free: acquire synchronously so two calls in the same synchronous
      // turn cannot both observe depth 0 and run concurrently.
      _depth++;
      return runZoned(() async {
        try {
          return await action();
        } finally {
          _release();
        }
      }, zoneValues: {_reentryKey: Object()});
    }
    // Busy: queue FIFO. The permit is reserved at release time so a new
    // arrival can never slip in between "depth reached 0" and the woken
    // waiter actually starting.
    final completer = Completer<void>();
    _waiters.add(completer);
    return runZoned(() async {
      await completer.future;
      try {
        return await action();
      } finally {
        _release();
      }
    }, zoneValues: {_reentryKey: Object()});
  }

  static void _release() {
    if (_depth > 0) _depth--;
    if (_depth == 0 && _waiters.isNotEmpty) {
      _depth++;
      final next = _waiters.removeAt(0);
      next.complete();
    }
  }
}
