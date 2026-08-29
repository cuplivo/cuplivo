/// Cross-feature busy gate for backup-family operations.
///
/// The auto-snapshot scheduler checks [active] before firing so a timed
/// snapshot never races a manual WebDAV/S3 upload, a local export, or a
/// restore/import. Operations are reference-counted: nested funnels (a
/// snapshot itself calls the same DataSync export path) may safely re-enter.
final class BackupActivityGate {
  BackupActivityGate._();

  static int _depth = 0;

  /// True while any gated backup/restore/export operation is in flight.
  static bool get active => _depth > 0;

  /// Increments the in-flight counter. Always pair with [end] in `finally`.
  static void begin() => _depth++;

  /// Decrements the in-flight counter (clamped at zero for safety).
  static void end() {
    if (_depth > 0) _depth--;
  }
}
