import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/chat_input_data.dart';
import '../utils/multimodal_input_utils.dart';
import '../../utils/app_directories.dart';
import 'inbound_share.dart';

/// Result of importing a share's staged files into the app upload directory.
class InboundShareImportOutcome {
  const InboundShareImportOutcome({
    required this.input,
    required this.failedCount,
  });

  final ChatInputData input;
  final int failedCount;

  bool get isEmpty =>
      input.text.trim().isEmpty &&
      input.imagePaths.isEmpty &&
      input.documents.isEmpty;
}

/// Imports files a share staged outside the app sandbox into the app's own
/// upload directory, so shared attachments share the normal lifecycle (dedup
/// naming, storage guardrail, backup/sync scope). Native stages; Dart imports
/// and then removes the staging directory. See CONTEXT.md → Inbound Share.
class InboundShareImporter {
  InboundShareImporter._();

  /// Total byte budget for one share. Android's native staging enforces the
  /// same number before copying; this is the cross-platform enforcement point
  /// for iOS, whose extension only bounds the item count.
  static const int maxInboundTotalBytes = 200 * 1024 * 1024;

  static const String _stagingRootName = 'share_inbox';
  static const int _maxNameLength = 200;

  static Future<InboundShareImportOutcome> import(
    InboundSharePayload payload,
  ) async {
    final directory = await AppDirectories.getUploadDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final images = <String>[];
    final documents = <DocumentAttachment>[];
    var failedCount = 0;
    var remainingBytes = maxInboundTotalBytes;

    for (final source in payload.imagePaths) {
      final copied = await _copyInto(
        source,
        directory,
        maxBytes: remainingBytes,
      );
      if (copied == null) {
        failedCount++;
        continue;
      }
      remainingBytes -= copied.bytes;
      images.add(copied.path);
    }

    for (final file in payload.files) {
      final copied = await _copyInto(
        file.path,
        directory,
        preferredName: file.name,
        maxBytes: remainingBytes,
      );
      if (copied == null) {
        failedCount++;
        continue;
      }
      remainingBytes -= copied.bytes;
      final name = p.basename(copied.path);
      final mime = file.mime.isNotEmpty
          ? file.mime
          : inferMediaMimeFromSource(
              name,
              fallbackMime: 'application/octet-stream',
            );
      documents.add(
        DocumentAttachment(path: copied.path, fileName: name, mime: mime),
      );
    }

    await _cleanupStaging(payload.stagingDir);

    return InboundShareImportOutcome(
      input: ChatInputData(
        text: payload.text ?? '',
        imagePaths: images,
        documents: documents,
      ),
      failedCount: failedCount + payload.failedCount,
    );
  }

  static Future<({String path, int bytes})?> _copyInto(
    String source,
    Directory directory, {
    String? preferredName,
    required int maxBytes,
  }) async {
    if (source.isEmpty) return null;
    File? destination;
    try {
      final sourceFile = File(source);
      if (!await sourceFile.exists()) {
        debugPrint('[InboundShare] staged file missing: $source');
        return null;
      }
      if (await FileSystemEntity.type(source) != FileSystemEntityType.file) {
        debugPrint('[InboundShare] staged entry is not a file: $source');
        return null;
      }
      final size = await sourceFile.length();
      if (size > maxBytes) {
        debugPrint(
          '[InboundShare] staged file exceeds the share budget '
          '($size > $maxBytes): $source',
        );
        return null;
      }
      final safeName = _safeName(preferredName ?? source);
      destination = await _dedupedTarget(directory, safeName);
      // Streamed copy: shares are unbounded (video/archive), so reading the
      // whole file into memory risks an OOM kill on mobile.
      final sink = destination.openWrite();
      try {
        await sink.addStream(sourceFile.openRead());
        await sink.flush();
      } finally {
        await sink.close();
      }
      // Preserve mtime like the other uploaders: backup/LAN sync and the
      // duplicate dialog filter on it.
      try {
        await destination.setLastModified(await sourceFile.lastModified());
      } catch (error) {
        debugPrint(
          '[InboundShare] mtime preserve failed for ${destination.path}: '
          '$error',
        );
      }
      return (path: destination.path, bytes: size);
    } catch (error, stackTrace) {
      debugPrint('[InboundShare] copy failed for $source: $error\n$stackTrace');
      await _deletePartial(destination);
      return null;
    }
  }

  /// Removes a half-written destination after a failed copy so a later import
  /// can never pick up a truncated file.
  static Future<void> _deletePartial(File? destination) async {
    if (destination == null) return;
    try {
      if (await destination.exists()) await destination.delete();
    } catch (error) {
      debugPrint(
        '[InboundShare] partial copy cleanup failed for '
        '${destination.path}: $error',
      );
    }
  }

  static Future<File> _dedupedTarget(Directory directory, String name) async {
    var candidate = File(p.join(directory.path, name));
    if (!await candidate.exists()) return candidate;
    final base = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var counter = 1;
    while (await candidate.exists()) {
      candidate = File(p.join(directory.path, '$base($counter)$extension'));
      counter++;
    }
    return candidate;
  }

  /// Basename-only, control/separator/bracket-stripped file name. Never
  /// yields empty, `.`, `..`, or a path fragment, so a shared file cannot
  /// escape the upload directory. Brackets are stripped because the file name
  /// is embedded in the `[file:path|name|mime]` message marker.
  static String _safeName(String raw) {
    final parts = raw.split(RegExp(r'[\\/]'));
    var name = parts.isEmpty ? '' : parts.last;
    name = name.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|\[\]]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      name = 'shared_${DateTime.now().microsecondsSinceEpoch}';
    }
    if (name.length <= _maxNameLength) return name;
    // Preserve the extension when truncating: mime inference depends on it.
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) {
      return name.substring(0, _maxNameLength);
    }
    final extension = name.substring(dot);
    final keep = _maxNameLength - extension.length;
    return keep <= 0
        ? name.substring(0, _maxNameLength)
        : '${name.substring(0, keep)}$extension';
  }

  /// Removes the per-share staging directory after import. Guarded against
  /// deleting a filesystem root or the upload directory itself.
  static Future<void> _cleanupStaging(String? stagingDir) async {
    if (stagingDir == null || stagingDir.isEmpty) return;
    try {
      final directory = Directory(stagingDir);
      if (!await directory.exists()) return;
      if (_isUnsafeToDelete(
        stagingDir,
        await AppDirectories.getUploadDirectory(),
      )) {
        debugPrint(
          '[InboundShare] refusing to delete unsafe staging: $stagingDir',
        );
        return;
      }
      await directory.delete(recursive: true);
    } catch (error, stackTrace) {
      debugPrint(
        '[InboundShare] staging cleanup failed for $stagingDir: '
        '$error\n$stackTrace',
      );
    }
  }

  static bool _isUnsafeToDelete(String stagingDir, Directory uploadDir) {
    final canonical = AppDirectories.canonPath(stagingDir);
    if (AppDirectories.isFilesystemRootPath(canonical)) return true;
    if (AppDirectories.isPathInside(uploadDir.path, canonical) ||
        AppDirectories.isPathInside(canonical, uploadDir.path)) {
      return true;
    }
    // Positive containment: only ever delete what the native layer stages
    // into — <cache|App Group>/share_inbox/<uuid>.
    final segments = p.split(canonical);
    final inboxIndex = segments.lastIndexOf(_stagingRootName);
    return inboxIndex < 0 || inboxIndex == segments.length - 1;
  }
}
