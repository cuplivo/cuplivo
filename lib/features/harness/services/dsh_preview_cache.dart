import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Why a remote file could not be materialized for a local-file preview.
enum DshPreviewCacheFailure {
  /// The body is larger than the cache's per-entry cap, so writing it would
  /// blow the preview budget.
  tooLarge,

  /// The local cache directory could not be read or written.
  io,
}

/// Thrown by [DshPreviewCache]; the preview page maps it to a localized card.
class DshPreviewCacheException implements Exception {
  const DshPreviewCacheException(this.failure, this.message, {this.cause});

  final DshPreviewCacheFailure failure;
  final String message;
  final Object? cause;

  @override
  String toString() => 'DshPreviewCacheException(${failure.name}: $message)';
}

/// Bounded, per-remote on-disk materialization of DeepSeek Harness files.
///
/// Cuplivo's existing preview widgets are `File`-based (`buildFilePreviewBody`,
/// `classifyFilePreview`, markdown/code/csv/image readers), so the harness
/// slice writes a remote body into one temp file and reuses those widgets
/// unchanged. This class owns only the temp-file policy:
///
/// * one directory per remote and session, so a cache sweep can be scoped and
///   two hosts with same-named files never collide;
/// * the original basename and extension are preserved (classification is
///   extension/sniff based) with a stable content-independent hash prefix for
///   same-name files in one directory;
/// * a per-entry cap, plus a total cap derived from it, so the cache cannot
///   grow without bound across sessions. Writes are serialized so two pages
///   materializing at once cannot race the trim.
class DshPreviewCache {
  DshPreviewCache({
    Directory? root,
    this.maxEntryBytes = kDshPreviewEntryLimit,
    int? totalLimit,
  }) : maxTotalBytes =
           totalLimit ?? maxEntryBytes * kDshPreviewTotalEntryFactor,
       root = root ?? Directory(p.join(Directory.systemTemp.path, _rootName)) {
    assert(maxEntryBytes > 0, 'the cache must accept at least one byte');
    assert(
      maxTotalBytes >= maxEntryBytes,
      'the cache total must fit at least one entry',
    );
  }

  /// Largest body the cache accepts for one file.
  static const int kDshPreviewEntryLimit = 8 * 1024 * 1024;

  /// Default total budget is this many entries; derived so the two limits
  /// cannot drift apart.
  static const int kDshPreviewTotalEntryFactor = 3;

  static const String _rootName = 'cuplivo-dsh-preview';

  final Directory root;
  final int maxEntryBytes;
  final int maxTotalBytes;

  Future<void> _queue = Future<void>.value();

  Future<File> materializeText({
    required String remoteId,
    required String sessionId,
    required String path,
    required String text,
  }) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    return materializeBytes(
      remoteId: remoteId,
      sessionId: sessionId,
      path: path,
      bytes: bytes,
    );
  }

  Future<File> materializeBytes({
    required String remoteId,
    required String sessionId,
    required String path,
    required List<int> bytes,
  }) {
    if (bytes.length > maxEntryBytes) {
      return Future<File>.error(
        DshPreviewCacheException(
          DshPreviewCacheFailure.tooLarge,
          'The file is ${bytes.length} bytes; the preview cap is '
          '$maxEntryBytes bytes',
        ),
      );
    }
    return _serialized(
      () => _write(
        remoteId: remoteId,
        sessionId: sessionId,
        path: path,
        bytes: bytes,
      ),
    );
  }

  /// Current byte count under [root]; used by tests and diagnostics.
  Future<int> currentTotalBytes() async {
    var total = 0;
    if (!await root.exists()) return total;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          continue;
        }
      }
    }
    return total;
  }

  /// Removes the whole cache. Safe to call when nothing was written.
  Future<void> clear() async {
    try {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    } on FileSystemException catch (error) {
      throw DshPreviewCacheException(
        DshPreviewCacheFailure.io,
        'Could not clear the preview cache',
        cause: error,
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<File> _write({
    required String remoteId,
    required String sessionId,
    required String path,
    required List<int> bytes,
  }) async {
    final directory = Directory(
      p.join(root.path, _safeSegment(remoteId), _safeSegment(sessionId)),
    );
    final file = File(p.join(directory.path, _cacheFileName(path)));
    try {
      await directory.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      await _trim(keepPath: file.path);
      return file;
    } on FileSystemException catch (error) {
      throw DshPreviewCacheException(
        DshPreviewCacheFailure.io,
        'Could not write the preview cache',
        cause: error,
      );
    }
  }

  Future<void> _trim({required String keepPath}) async {
    if (!await root.exists()) return;
    final entries = <({File file, int bytes, DateTime modified})>[];
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        final length = await entity.length();
        final modified = (await entity.stat()).modified;
        entries.add((file: entity, bytes: length, modified: modified));
        total += length;
      } on FileSystemException {
        continue;
      }
    }
    if (total <= maxTotalBytes) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= maxTotalBytes) break;
      if (entry.file.path == keepPath) continue;
      try {
        await entry.file.delete();
        total -= entry.bytes;
      } on FileSystemException {
        continue;
      }
    }
  }

  String _cacheFileName(String path) {
    final basename = _safeFileName(p.basename(path));
    return '${_fnv1a32Hex(path)}-$basename';
  }

  /// Collapses `..` runs so a sanitized path can never contain a traversal
  /// segment (the parent-directory token itself is the dangerous part, not the
  /// separators).
  static String _collapseDotRuns(String value) =>
      value.replaceAll(RegExp(r'\.{2,}'), '_');

  static String _safeFileName(String name) {
    var safe = _collapseDotRuns(
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
    );
    if (safe.isEmpty || safe == '.' || safe == '..') {
      safe = 'file';
    }
    // Keep the extension (the preview classification reads it) by trimming the
    // stem, not the tail.
    if (safe.length > 96) {
      final extension = p.extension(safe);
      final stemLimit = 96 - extension.length;
      safe = stemLimit <= 0
          ? safe.substring(safe.length - 96)
          : '${safe.substring(0, stemLimit)}$extension';
    }
    return safe;
  }

  static String _safeSegment(String value) {
    final safe = _collapseDotRuns(
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
    );
    return safe.isEmpty || safe == '.' || safe == '..' ? 'unknown' : safe;
  }

  /// Deterministic 32-bit FNV-1a, hex-padded. Not a security hash: it only
  /// keeps same-named files from different directories apart in the cache.
  static String _fnv1a32Hex(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
