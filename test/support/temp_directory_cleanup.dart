import 'dart:io';

/// Deletes [directory], retrying while the OS still reports an open handle.
///
/// A preview reader, an image decode or a controller's database close can keep
/// a file open for a moment after the test body finishes. POSIX unlinks it
/// anyway, but Windows fails with `errno = 32` ("the file is in use"), and that
/// failure lands in `tearDown` while the assertion that actually broke the test
/// is already reported. Retrying gives the handle a bounded window to close; a
/// leak that never clears is rethrown so it stays visible — unless
/// [keepLockedLeftovers] is set, for tests whose harness keeps its reader or
/// database open past the test and which therefore cannot win the unlink on
/// Windows at all.
Future<void> deleteDirectoryWhenReleased(
  Directory directory, {
  int attempts = 20,
  Duration delay = const Duration(milliseconds: 50),
  bool keepLockedLeftovers = false,
}) async {
  for (var attempt = 0; ; attempt++) {
    if (!await directory.exists()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= attempts - 1) {
        if (keepLockedLeftovers) return;
        rethrow;
      }
      await Future<void>.delayed(delay);
    }
  }
}
