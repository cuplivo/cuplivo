import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Ensures [logsDir] exists, rotates the active log aside when its last
/// modification was on an earlier day, and returns an append sink for
/// [activeFileName].
///
/// The rotated file is named `<rotatedFilePrefix>yyyy-MM-dd.txt`, with a
/// `_<n>` suffix when that name already exists. Failures are reported with the
/// resolved active path and rethrown so callers keep control over error
/// handling.
Future<IOSink> openDailyRotatingLogSink({
  required Directory logsDir,
  required String activeFileName,
  required String rotatedFilePrefix,
  required DateTime now,
}) async {
  final activePath = p.join(logsDir.path, activeFileName);
  try {
    if (!await logsDir.exists()) {
      await logsDir.create(recursive: true);
    }

    final today = DateTime(now.year, now.month, now.day);
    final active = File(activePath);
    if (await active.exists()) {
      final stat = await active.stat();
      final local = stat.modified.toLocal();
      final fileDay = DateTime(local.year, local.month, local.day);
      if (fileDay != today) {
        final suffix = _formatDay(fileDay);
        var rotated = File(
          p.join(logsDir.path, '$rotatedFilePrefix$suffix.txt'),
        );
        if (await rotated.exists()) {
          var i = 1;
          while (await File(
            p.join(logsDir.path, '$rotatedFilePrefix${suffix}_$i.txt'),
          ).exists()) {
            i++;
          }
          rotated = File(
            p.join(logsDir.path, '$rotatedFilePrefix${suffix}_$i.txt'),
          );
        }
        await active.rename(rotated.path);
      }
    }

    return active.openWrite(mode: FileMode.append);
  } catch (e) {
    debugPrint('openDailyRotatingLogSink: failed for $activePath: $e');
    rethrow;
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

String _formatDay(DateTime dt) =>
    '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
