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

    for (final source in payload.imagePaths) {
      final destination = await _copyInto(source, directory);
      if (destination == null) {
        failedCount++;
        continue;
      }
      images.add(destination);
    }

    for (final file in payload.files) {
      final destination = await _copyInto(
        file.path,
        directory,
        preferredName: file.name,
      );
      if (destination == null) {
        failedCount++;
        continue;
      }
      final name = p.basename(destination);
      final mime = file.mime.isNotEmpty
          ? file.mime
          : inferMediaMimeFromSource(
              name,
              fallbackMime: 'application/octet-stream',
            );
      documents.add(
        DocumentAttachment(path: destination, fileName: name, mime: mime),
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

  static Future<String?> _copyInto(
    String source,
    Directory directory, {
    String? preferredName,
  }) async {
    if (source.isEmpty) return null;
    try {
      final sourceFile = File(source);
      if (!await sourceFile.exists()) {
        debugPrint('[InboundShare] staged file missing: $source');
        return null;
      }
      final safeName = _safeName(preferredName ?? source);
      final destination = await _dedupedTarget(directory, safeName);
      await destination.writeAsBytes(
        await sourceFile.readAsBytes(),
        flush: true,
      );
      return destination.path;
    } catch (error, stackTrace) {
      debugPrint('[InboundShare] copy failed for $source: $error\n$stackTrace');
      return null;
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

  /// Basename-only, control/separator-stripped file name. Never yields empty,
  /// `.`, `..`, or a path fragment, so a shared file cannot escape the upload
  /// directory.
  static String _safeName(String raw) {
    final parts = raw.split(RegExp(r'[\\/]'));
    var name = parts.isEmpty ? '' : parts.last;
    name = name.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      name = 'shared_${DateTime.now().microsecondsSinceEpoch}';
    }
    return name.length > 200 ? name.substring(0, 200) : name;
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
    return AppDirectories.isPathInside(uploadDir.path, canonical) ||
        AppDirectories.isPathInside(canonical, uploadDir.path);
  }
}
