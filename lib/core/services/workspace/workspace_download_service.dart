import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../fetch/web_fetch_target_guard.dart' as guard;

/// Result of a successful [WorkspaceDownloadService.download] call.
class WorkspaceDownloadResult {
  final String url;
  final String wirePath;
  final int downloadedBytes;

  const WorkspaceDownloadResult({
    required this.url,
    required this.wirePath,
    required this.downloadedBytes,
  });
}

class WorkspaceDownloadException implements Exception {
  final String message;

  const WorkspaceDownloadException(this.message);

  @override
  String toString() => message;
}

/// Cancellation signal for a workspace download. Completer-based so both the
/// download service (which races each chunk against it) and the
/// `DownloadProgressStore` (which aborts every download of a stopped
/// conversation) can observe and trigger it.
final class WorkspaceDownloadAbortToken {
  final Completer<void> _completer = Completer<void>();

  bool get isAborted => _completer.isCompleted;
  Future<void> get whenAborted => _completer.future;

  void abort() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void throwIfAborted() {
    if (isAborted) throw const WorkspaceDownloadCancelledException();
  }
}

final class WorkspaceDownloadCancelledException implements Exception {
  const WorkspaceDownloadCancelledException();

  @override
  String toString() => 'Workspace download was cancelled';
}

const Object _downloadCancelledMarker = Object();

/// Downloads URLs into the bound workspace as a local tool (sibling of
/// `read`/`write`/...).
///
/// The model-facing `download(url, path)` tool saves the response bytes
/// as-is (binary allowed) to a mount-relative full file path. Bytes stream to
/// a unique `.part` file inside the mount's `.fetch_cache/`, then install
/// onto the target atomically (backup + rollback on Windows semantics); a
/// crash leaves only a `.part` aged out by the TTL pass. Never buffers the
/// body in memory.
class WorkspaceDownloadService {
  WorkspaceDownloadService._();

  static const String _defaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// `.fetch_cache/` eviction budget (512 MB) and TTL (7 days), per CONTEXT.md
  /// "Fetch temp storage". Mutable statics only so tests can shrink them;
  /// production values are fixed, no settings.
  @visibleForTesting
  static int cacheBudgetBytes = 512 * 1024 * 1024;
  @visibleForTesting
  static Duration cacheTtl = const Duration(days: 7);

  /// A `.part`/`.bak` file whose mtime is older than this is crashed, not
  /// in-flight, so the budget pass may evict it. Heuristic, not a guarantee:
  /// `IOSink` buffers, so a slow trickle download (< buffer size between
  /// long gaps, each resetting the 60 s chunk timeout) keeps a stale mtime
  /// past the grace and can be budget-evicted mid-transfer — on POSIX that
  /// orphans the write and the install fails gracefully with an error, on
  /// Windows the delete fails harmlessly (open handle). Grace = 60× the
  /// chunk timeout for normal transfers. Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration partGracePeriod = const Duration(hours: 1);

  /// Per-chunk inactivity timeout for download streams. A moving download
  /// never trips it; a stalled peer fails instead of hanging the tool call.
  /// Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration downloadChunkTimeout = const Duration(minutes: 1);

  /// Timeout for the TCP connect + response-header phase of a download.
  /// `client.send` is otherwise unbounded (a blackholed connection never
  /// produces a chunk, so the chunk timeout can't fire). Mutable only so
  /// tests can shrink it.
  @visibleForTesting
  static Duration downloadResponseTimeout = const Duration(seconds: 30);

  /// Downloads [url] to [target] (a full-file host path under the bound
  /// workspace) via [cacheDir] (the mount's `.fetch_cache/` staging area).
  /// [wirePath] is the mount-relative display path used in messages and
  /// errors. The caller is responsible for wire-path validation and the
  /// read-only check — this service only transfers bytes.
  ///
  /// [onProgress] fires on every received chunk with the cumulative byte
  /// count and the server-declared total (null when unknown — chunked
  /// transfer or a missing Content-Length). [abortToken], when provided,
  /// force-aborts the transfer: the raw client is force-closed and a
  /// [WorkspaceDownloadCancelledException] is thrown, leaving no partial file
  /// installed.
  static Future<WorkspaceDownloadResult> download({
    required Uri url,
    required File target,
    required Directory cacheDir,
    required String wirePath,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    WorkspaceDownloadAbortToken? abortToken,
  }) async {
    final tmp = File(
      p.join(
        cacheDir.path,
        '${_cacheKey(url)}_${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );
    // Byte-exact transfer: the default client auto-decompresses gzip and adds
    // Accept-Encoding: gzip, which would silently change the saved bytes and
    // the reported size. Download mode saves the wire bytes as-is. The raw
    // client is held so timeouts can force-close the socket (a non-force
    // close leaves blackholed connections alive until the OS TCP timeout).
    // Redirects are followed manually so every hop is SSRF-revalidated.
    final rawClient = HttpClient()..autoUncompress = false;
    final client = IOClient(rawClient);
    var size = 0;
    try {
      await cacheDir.create(recursive: true);
      abortToken?.throwIfAborted();
      final resp = await _sendWithRedirectGuard(
        client,
        url,
        downloadResponseTimeout,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final expectedTotal =
          resp.contentLength != null && resp.contentLength! > 0
          ? resp.contentLength
          : null;
      onProgress?.call(0, expectedTotal);
      // The IOSink buffers; its first I/O error surfaces at flush()/close().
      // A partial file must never be installed or reported as a success —
      // any write failure aborts the download.
      final sink = tmp.openWrite();
      var sinkFailed = false;
      try {
        try {
          final iterator = StreamIterator<List<int>>(
            resp.stream.timeout(downloadChunkTimeout),
          );
          try {
            while (await _moveNextOrAbort(iterator, abortToken)) {
              final chunk = iterator.current;
              sink.add(chunk);
              size += chunk.length;
              onProgress?.call(size, expectedTotal);
            }
            abortToken?.throwIfAborted();
            await sink.flush();
          } finally {
            await iterator.cancel();
          }
        } finally {
          try {
            await sink.close();
          } catch (e) {
            sinkFailed = true;
            debugPrint('[workspace/download] closing download sink failed: $e');
          }
        }
      } catch (e) {
        sinkFailed = true;
        rethrow;
      }
      if (sinkFailed) {
        throw Exception('failed to write downloaded bytes to disk');
      }
      await target.parent.create(recursive: true);
      await _install(target, tmp, cacheDir);
      return WorkspaceDownloadResult(
        url: url.toString(),
        wirePath: wirePath,
        downloadedBytes: size,
      );
    } on WorkspaceDownloadCancelledException {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (cleanupErr) {
        debugPrint('[workspace/download] failed to clean up $tmp: $cleanupErr');
      }
      rethrow;
    } catch (e) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (cleanupErr) {
        debugPrint('[workspace/download] failed to clean up $tmp: $cleanupErr');
      }
      throw WorkspaceDownloadException(
        'Failed to download ${url.toString()}: '
        '${e is Exception ? e.toString() : 'Unknown error'}',
      );
    } finally {
      // Keep `.fetch_cache/` temp storage under TTL/budget (stale `.part`
      // files from crashed downloads).
      await _evictCache(cacheDir, justWritten: tmp);
      rawClient.close(force: true);
    }
  }

  /// Advances the download stream by one chunk, racing against [abortToken].
  /// Returns false when the stream is exhausted; throws
  /// [WorkspaceDownloadCancelledException] when the token fires first.
  static Future<bool> _moveNextOrAbort(
    StreamIterator<List<int>> iterator,
    WorkspaceDownloadAbortToken? abortToken,
  ) async {
    abortToken?.throwIfAborted();
    if (abortToken == null) return iterator.moveNext();
    final result = await Future.any<Object>([
      iterator.moveNext(),
      abortToken.whenAborted.then<Object>((_) => _downloadCancelledMarker),
    ]);
    if (identical(result, _downloadCancelledMarker)) {
      throw const WorkspaceDownloadCancelledException();
    }
    return result as bool;
  }

  /// Sends the download request, following redirects manually so each hop is
  /// re-validated by the SSRF guard before a socket opens. The streamed
  /// response body is drained on redirect hops (the download mode never
  /// buffers non-final bodies). Redirects are capped at
  /// [guard.WebFetchTargetGuard.maxRedirectHops].
  static Future<http.StreamedResponse> _sendWithRedirectGuard(
    http.Client client,
    Uri url,
    Duration timeout,
  ) async {
    var current = url;
    for (var hop = 0; hop <= guard.WebFetchTargetGuard.maxRedirectHops; hop++) {
      final reason = await guard.webFetchTargetBlockReason(current);
      if (reason != null) {
        throw Exception(reason);
      }
      final req = http.Request('GET', current)
        ..headers['User-Agent'] = _defaultUA
        ..headers['Accept-Encoding'] = 'identity'
        ..followRedirects = false;
      final response = await client.send(req).timeout(timeout);
      if (!_isRedirect(response.statusCode)) return response;
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null || location.isEmpty) {
        throw Exception('Redirect without a Location header');
      }
      current = current.resolve(location);
    }
    throw Exception('Too many redirects');
  }

  static bool _isRedirect(int statusCode) =>
      statusCode >= 300 && statusCode < 400;

  /// Replaces [target] with the completed [tmp] file. Windows cannot rename
  /// onto an existing path, so the old file is staged to a unique backup
  /// INSIDE `.fetch_cache/` first (same volume, atomic; a crash between the
  /// two renames leaves only a backup that the eviction passes age out). If
  /// the install rename fails, the backup is restored — the previous content
  /// survives, never a delete-then-rename window.
  static Future<void> _install(
    File target,
    File tmp,
    Directory cacheDir,
  ) async {
    if (await Directory(target.path).exists()) {
      throw Exception('a directory already exists at ${target.path}');
    }
    if (!await target.exists()) {
      await tmp.rename(target.path);
      return;
    }
    final backup = File(
      p.join(
        cacheDir.path,
        '${p.basename(target.path)}_${DateTime.now().microsecondsSinceEpoch}.bak',
      ),
    );
    try {
      await target.rename(backup.path);
    } catch (e) {
      // Common cause: a concurrent download to the SAME target already
      // staged/replaced it. The loser's failure is recoverable by retry.
      throw Exception(
        'failed to stage the existing target ${target.path} for overwrite '
        '(a concurrent download may target the same path; retry): $e',
      );
    }
    try {
      await tmp.rename(target.path);
    } catch (e) {
      try {
        await backup.rename(target.path);
      } catch (restoreErr) {
        debugPrint(
          '[workspace/download] failed to restore $target from $backup: '
          '$restoreErr',
        );
      }
      rethrow;
    }
    try {
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (e) {
      debugPrint('[workspace/download] failed to delete backup $backup: $e');
    }
  }

  /// Deterministic cache key: sha256 over the URL. Naming only — no reuse.
  static String _cacheKey(Uri url) => crypto.sha256
      .convert(utf8.encode(url.toString()))
      .toString()
      .substring(0, 16);

  /// `.fetch_cache/` eviction (CONTEXT.md "Fetch temp storage"), run after
  /// every cache-dir write (download temp files):
  /// 1. TTL pass: delete EVERYTHING (including `.part`/`.bak` files — crashed
  ///    downloads/installs age out) older than [cacheTtl].
  /// 2. Budget pass: delete oldest-first, excluding [justWritten] (the
  ///    current download's temp) and ANY file fresher than
  ///    [partGracePeriod] — a fresh file may be an in-flight parallel
  ///    download's temp or an install-phase backup; budget eviction only
  ///    trims files older than the grace (the cache may transiently exceed
  ///    the budget by an hour of writes). Older entries are evictable
  ///    regardless of extension.
  /// Best effort — never errors the caller, all failures logged. Iteration
  /// is async so the app isolate yields between files near the budget.
  static Future<void> _evictCache(
    Directory dir, {
    required File justWritten,
  }) async {
    final expiredBefore = DateTime.now().subtract(cacheTtl);
    final fresherThan = DateTime.now().subtract(partGracePeriod);
    try {
      await for (final ent in dir.list()) {
        if (ent is! File || ent.path == justWritten.path) continue;
        try {
          if (ent.statSync().modified.isBefore(expiredBefore)) {
            await ent.delete();
          }
        } catch (e) {
          debugPrint(
            '[workspace/download] eviction (ttl) failed for ${ent.path}: $e',
          );
        }
      }
      // Precompute (path, mtime, size) per entry: a file that vanishes
      // between list and stat (e.g. a concurrent download's `.part` being
      // renamed onto its target) must skip only ITSELF, not abort the
      // remaining budget eviction. statSync stays on the app isolate, but the
      // 512 MB budget bounds the entry count (typically ≤ ~20–50 files).
      final entries = <({String path, DateTime modified, int size})>[];
      await for (final ent in dir.list()) {
        if (ent is! File || ent.path == justWritten.path) continue;
        try {
          final stat = ent.statSync();
          entries.add((
            path: ent.path,
            modified: stat.modified,
            size: stat.size,
          ));
        } catch (e) {
          debugPrint(
            '[workspace/download] eviction (stat) skipped ${ent.path}: $e',
          );
        }
      }
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      var total = entries.fold<int>(0, (sum, e) => sum + e.size);
      for (final e in entries) {
        if (total <= cacheBudgetBytes) break;
        if (!e.modified.isBefore(fresherThan)) {
          continue;
        }
        try {
          await File(e.path).delete();
          total -= e.size;
        } catch (err) {
          debugPrint(
            '[workspace/download] eviction (budget) failed for ${e.path}: $err',
          );
        }
      }
    } catch (e) {
      debugPrint('[workspace/download] eviction pass failed: $e');
    }
  }
}
