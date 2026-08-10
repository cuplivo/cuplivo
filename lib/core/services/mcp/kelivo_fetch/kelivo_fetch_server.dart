import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:html2md/html2md.dart' as html2md;
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../../utils/app_directories.dart';
import '../kelivo_filesystem/kelivo_filesystem_server.dart'
    show isSafeWireSegment, KelivoFilesystemMcpServerEngine;

/// @kelivo/fetch — In-memory MCP server engine and transport (Flutter/Dart)
///
/// Provides one token-conscious `fetch` tool. HTML is simplified to Markdown
/// by default, while raw content requires an explicit opt-in. Responses are
/// bounded and can be continued with `start_index`.
///
/// `download_path` saves fetched bytes as-is into `@workspaces` (binary
/// allowed); without it, over-length content is stored in
/// `@workspaces/.fetch_cache/` and the path is returned. See CONTEXT.md
/// "@kelivo/fetch (Built-in Fetch Tool)".
///
/// The server implements a minimal subset of MCP over JSON-RPC 2.0:
/// initialize, tools/list, tools/call. It is intended to run in the same
/// isolate as the Flutter app and connect to a standard mcp.Client via an
/// in-memory ClientTransport.

class KelivoFetchRequestPayload {
  static const defaultMaxLength = 5000;
  static const maximumMaxLength = 20000;

  final Uri url;
  final Map<String, String> headers;
  final int maxLength;
  final int startIndex;
  final bool raw;

  /// Full wire path under `@workspaces/` (validated), or null for text mode.
  final String? downloadPath;

  KelivoFetchRequestPayload({
    required this.url,
    Map<String, String>? headers,
    this.maxLength = defaultMaxLength,
    this.startIndex = 0,
    this.raw = false,
    this.downloadPath,
  }) : headers = headers ?? const {};

  static KelivoFetchRequestPayload parse(Object? args) {
    if (args is! Map) {
      throw ArgumentError(
        'Invalid arguments: expected an object containing url',
      );
    }
    final map = args.cast<String, dynamic>();
    final urlRaw = (map['url'] ?? '').toString().trim();
    final uri = Uri.tryParse(urlRaw);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('Invalid url: $urlRaw');
    }
    final headersAny = map['headers'];
    final headers = <String, String>{};
    if (headersAny is Map) {
      headersAny.forEach((k, v) {
        if (k == null || v == null) return;
        headers[k.toString()] = v.toString();
      });
    }
    final downloadRaw = map['download_path'];
    final downloadPath = downloadRaw == null
        ? null
        : _validateDownloadPath(downloadRaw.toString());
    if (downloadPath != null) {
      // Download mode: bytes are saved as-is; max_length, start_index and
      // raw are ignored entirely (not even type-validated).
      return KelivoFetchRequestPayload(
        url: uri,
        headers: headers,
        downloadPath: downloadPath,
      );
    }
    final maxLength = _parseInteger(
      map['max_length'],
      name: 'max_length',
      defaultValue: defaultMaxLength,
    );
    if (maxLength < 1 || maxLength > maximumMaxLength) {
      throw ArgumentError(
        'Invalid max_length: expected a value from 1 to $maximumMaxLength',
      );
    }
    final startIndex = _parseInteger(
      map['start_index'],
      name: 'start_index',
      defaultValue: 0,
    );
    if (startIndex < 0) {
      throw ArgumentError('Invalid start_index: expected a non-negative value');
    }
    final rawAny = map['raw'];
    if (rawAny != null && rawAny is! bool) {
      throw ArgumentError('Invalid raw: expected a boolean');
    }

    return KelivoFetchRequestPayload(
      url: uri,
      headers: headers,
      maxLength: maxLength,
      startIndex: startIndex,
      raw: rawAny as bool? ?? false,
    );
  }

  /// Validates [raw] as a full-file wire path under `@workspaces/` only
  /// (ADR 0022 rules; the fetch built-in never touches external mounts).
  /// Directories are not allowed — the path IS the complete target file.
  static String _validateDownloadPath(String raw) {
    if (raw.trim() != raw) {
      throw ArgumentError(
        'Invalid download_path: leading/trailing whitespace is not allowed: $raw',
      );
    }
    const prefix = '@workspaces/';
    if (!raw.startsWith(prefix)) {
      throw ArgumentError(
        'Invalid download_path: must be a full file path under '
        '@workspaces/ (e.g. @workspaces/reports/q3.pdf). '
        'External mounts are not available to the fetch tool.',
      );
    }
    if (raw.endsWith('/')) {
      throw ArgumentError(
        'Invalid download_path: trailing slash is not allowed '
        '(a full file path is required, not a directory): $raw',
      );
    }
    if (raw.contains('\\')) {
      throw ArgumentError(
        'Invalid download_path: backslashes are not allowed; '
        'use forward slashes: $raw',
      );
    }
    for (final seg in raw.substring(prefix.length).split('/')) {
      if (!isSafeWireSegment(seg)) {
        throw ArgumentError('Invalid download_path: unsafe path segment: $raw');
      }
      if (seg.contains(':') || seg.contains('\u0000')) {
        throw ArgumentError(
          'Invalid download_path: segment contains invalid characters: $raw',
        );
      }
      if (seg.startsWith('.')) {
        // Dot-prefixed segments (e.g. `.fetch_cache/`, `.git/`, `.hidden/`)
        // are excluded from backup/sync and invisible to glob/grep — the
        // opposite of a permanent download target: the confirmation's own
        // browsing advice would silently fail and the file never backs up.
        // Mirrors the trash resolver's dot-segment rule.
        throw ArgumentError(
          'Invalid download_path: dot-prefixed segments are reserved '
          'system paths (e.g. .fetch_cache/); download to a regular '
          'workspace path instead.',
        );
      }
    }
    return raw;
  }

  static int _parseInteger(
    Object? value, {
    required String name,
    required int defaultValue,
  }) {
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw ArgumentError('Invalid $name: expected an integer');
  }
}

class KelivoFetcher {
  static const _defaultUA =
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

  /// Overflow text is only saved when its UTF-8 size fits `kelivo_read`'s
  /// read window — otherwise the model could never read the file back
  /// (single source of truth: the filesystem server's boundary). Mutable only
  /// so tests can shrink it.
  @visibleForTesting
  static int maxReadableTextBytes =
      KelivoFilesystemMcpServerEngine.readWindowBytes;

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

  /// Total-duration timeout for TEXT mode (`http.get` covers connect,
  /// headers and body in one unbounded future). Bounds what would otherwise
  /// hang until the client-side cap (10 min) — a blackholed page must fail
  /// fast for the model. Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration textFetchTimeout = const Duration(seconds: 60);

  static const _binarySniffBytes = 1024;

  static Future<http.Response> _fetch(KelivoFetchRequestPayload payload) async {
    // Explicit client so a timeout can force-close the socket: the default
    // `http.get` client only closes IDLE connections, leaving blackholed
    // sockets alive until the OS TCP timeout.
    final raw = HttpClient();
    final client = IOClient(raw);
    try {
      final resp = await client
          .get(payload.url, headers: _mergedHeaders(payload))
          .timeout(textFetchTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      return resp;
    } catch (e) {
      throw Exception(
        'Failed to fetch ${payload.url}: ${e is Exception ? e.toString() : 'Unknown error'}',
      );
    } finally {
      raw.close(force: true);
    }
  }

  static Map<String, String> _mergedHeaders(
    KelivoFetchRequestPayload payload,
  ) => <String, String>{'User-Agent': _defaultUA, ...payload.headers};

  static Future<Map<String, dynamic>> fetch(
    KelivoFetchRequestPayload payload, {
    Future<Directory> Function()? workspacesDirProvider,
  }) async {
    final downloadPath = payload.downloadPath;
    if (downloadPath != null) {
      // Download mode: bytes saved as-is; max_length/start_index/raw ignored.
      return _download(payload, downloadPath, workspacesDirProvider);
    }
    try {
      final resp = await _fetch(payload);
      final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
      final bytes = resp.bodyBytes;
      if (_looksBinary(bytes, contentType: contentType)) {
        return _err(
          'Possible binary content detected (binary content-type, or a null '
          'byte in the first $_binarySniffBytes bytes). If the payload is a '
          'file (image, PDF, archive, ...), re-call kelivo_fetch with '
          'download_path set (e.g. download_path: '
          '"@workspaces/download.bin") to save it as-is.',
        );
      }
      final body = _decodeBody(resp, bytes);
      final text = payload.raw
          ? body
          : _contentForModel(body, contentType: contentType);
      var result = _bounded(text, payload);
      if (payload.startIndex == 0 && text.length > payload.maxLength) {
        // Over-length on the first call: store the FULL converted content so
        // the model can read it in one kelivo_read call. Deterministic name,
        // no reuse — every call re-fetches and overwrites (CONTEXT.md).
        final byteLen = utf8.encode(text).length;
        if (byteLen > maxReadableTextBytes) {
          result =
              '$result\n\n[Content too large to save as text '
              '($byteLen bytes exceeds kelivo_read\'s '
              '${maxReadableTextBytes ~/ (1024 * 1024)} MB window). '
              'Re-call kelivo_fetch with download_path set to save it '
              'as-is.]';
        } else {
          final hint = await _saveOverflowText(
            payload,
            text,
            isMarkdown: !payload.raw && _isHtml(body, contentType: contentType),
            workspacesDirProvider: workspacesDirProvider,
          );
          if (hint != null) {
            result =
                '$result\n\nFull content (${text.length} characters) '
                'saved to $hint. Read it with kelivo_read to get the complete '
                'content.';
          }
        }
      }
      return _ok(result);
    } catch (e) {
      return _err(e.toString());
    }
  }

  /// Decodes the response body. When the content-type declares a charset,
  /// [resp.body]'s decoding is authoritative. Without a charset, HTTP defaults
  /// to latin-1, which mangles UTF-8 payloads (common on legacy CJK servers);
  /// prefer strict UTF-8 and fall back to [resp.body] only when the bytes are
  /// not valid UTF-8.
  static String _decodeBody(http.Response resp, List<int> bytes) {
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    if (RegExp(r'charset\s*=').hasMatch(ct)) {
      return resp.body;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return resp.body;
    }
  }

  /// True when the payload is likely binary: a NUL byte in the first
  /// [bytes] (reliable for UTF-16 text and NUL-heavy formats; note UTF-16
  /// text pages are deliberately rejected — `download_path` is the escape
  /// hatch, see CONTEXT.md), OR a binary content-type family. The content-type
  /// signal is advisory (some sites serve text as application/octet-stream —
  /// the model then uses `download_path` and reads the file back as text;
  /// false positives are recoverable, mojibake is not).
  static bool _looksBinary(List<int> bytes, {required String contentType}) {
    if (_isBinaryContentType(contentType)) return true;
    final n = math.min(bytes.length, _binarySniffBytes);
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  static bool _isBinaryContentType(String contentType) {
    const binaryPrefixes = [
      'image/',
      'audio/',
      'video/',
      'application/pdf',
      'application/zip',
      'application/gzip',
      'application/x-tar',
      'application/x-7z-compressed',
      'application/x-rar-compressed',
      'application/octet-stream',
    ];
    return binaryPrefixes.any(contentType.startsWith);
  }

  /// Downloads [payload] to [downloadPath] (a validated `@workspaces/...`
  /// full file path). Streams to a unique `.part` file inside
  /// `.fetch_cache/`, then renames onto the target. Existing targets are
  /// replaced atomically via a backup name with rollback (a failed rename
  /// restores the previous file). A crash leaves only a `.part` inside the
  /// cache dir, aged out by the TTL pass. Never buffers the body in memory.
  static Future<Map<String, dynamic>> _download(
    KelivoFetchRequestPayload payload,
    String downloadPath,
    Future<Directory> Function()? workspacesDirProvider,
  ) async {
    final Directory ws;
    try {
      ws = await _resolveWorkspaces(workspacesDirProvider);
    } catch (e) {
      debugPrint('[kelivo_fetch] @workspaces sandbox unavailable: $e');
      return _err(
        'Failed to resolve the @workspaces sandbox: '
        '${e is Exception ? e.toString() : 'Unknown error'}',
      );
    }
    final rel = downloadPath.substring('@workspaces/'.length);
    final target = File(p.join(ws.path, rel));
    final cacheDir = Directory(p.join(ws.path, '.fetch_cache'));
    // Fail fast: a directory at the target path must never be replaced by a
    // file (schema: download_path is a full file path, not a directory).
    if (await Directory(target.path).exists()) {
      return _err(
        'Invalid download_path: a directory already exists at $downloadPath. '
        'download_path must be a full file path, not a directory.',
      );
    }
    final tmp = File(
      p.join(
        cacheDir.path,
        '${_cacheKey(payload)}_${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );
    // Byte-exact transfer: the default client auto-decompresses gzip and adds
    // Accept-Encoding: gzip, which would silently change the saved bytes and
    // the reported size. Download mode saves the wire bytes as-is. The raw
    // client is held so timeouts can force-close the socket (a non-force
    // close leaves blackholed connections alive until the OS TCP timeout).
    final rawClient = HttpClient()..autoUncompress = false;
    final client = IOClient(rawClient);
    var size = 0;
    try {
      await cacheDir.create(recursive: true);
      final req = http.Request('GET', payload.url)
        ..headers.addAll(_mergedHeaders(payload))
        ..headers['Accept-Encoding'] = 'identity';
      final resp = await client.send(req).timeout(downloadResponseTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      // The IOSink buffers; its first I/O error surfaces at flush()/close().
      // A partial file must never be installed or reported as a success —
      // any write failure aborts the download.
      final sink = tmp.openWrite();
      var sinkFailed = false;
      try {
        try {
          await for (final chunk in resp.stream.timeout(downloadChunkTimeout)) {
            sink.add(chunk);
            size += chunk.length;
          }
          await sink.flush();
        } finally {
          try {
            await sink.close();
          } catch (e) {
            sinkFailed = true;
            debugPrint('[kelivo_fetch] closing download sink failed: $e');
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
      return _ok(
        'Downloaded $size bytes to $downloadPath. '
        'Read it with kelivo_read (text files) or browse it with '
        'kelivo_glob/kelivo_list_directory. Note: max_length, start_index '
        'and raw are ignored when download_path is set.',
      );
    } catch (e) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (cleanupErr) {
        debugPrint('[kelivo_fetch] failed to clean up $tmp: $cleanupErr');
      }
      return _err(
        'Failed to download ${payload.url}: '
        '${e is Exception ? e.toString() : 'Unknown error'}',
      );
    } finally {
      // Keep `.fetch_cache/` temp storage under TTL/budget (stale `.part`
      // files from crashed downloads and overflow files).
      await _evictCache(cacheDir, justWritten: tmp);
      rawClient.close(force: true);
    }
  }

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
          '[kelivo_fetch] failed to restore $target from $backup: $restoreErr',
        );
      }
      rethrow;
    }
    try {
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (e) {
      debugPrint('[kelivo_fetch] failed to delete backup $backup: $e');
    }
  }

  /// Resolves the `@workspaces` sandbox directory (default:
  /// `AppDirectories.getWorkspacesDirectory`), creating it if missing.
  static Future<Directory> _resolveWorkspaces(
    Future<Directory> Function()? workspacesDirProvider,
  ) async {
    final dir =
        await (workspacesDirProvider ??
            AppDirectories.getWorkspacesDirectory)();
    await dir.create(recursive: true);
    return dir;
  }

  /// Deterministic cache key: sha256 over url + raw flag + sorted headers.
  /// Stable identity per fetch configuration (naming only — no reuse).
  static String _cacheKey(KelivoFetchRequestPayload payload) {
    final headerKeys = payload.headers.keys.toList()..sort();
    final canonical = [
      payload.url.toString(),
      payload.raw ? 'raw' : 'converted',
      for (final k in headerKeys) '$k:${payload.headers[k]}',
    ].join('\u0000');
    return crypto.sha256
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 16);
  }

  /// Saves the full converted text of an over-length fetch into
  /// `@workspaces/.fetch_cache/<key>.md|.txt` and runs the eviction pass.
  /// Returns the wire path, or null when the sandbox is unavailable (logged;
  /// the bounded text response still stands — recoverable environment issue).
  static Future<String?> _saveOverflowText(
    KelivoFetchRequestPayload payload,
    String text, {
    required bool isMarkdown,
    required Future<Directory> Function()? workspacesDirProvider,
  }) async {
    final Directory ws;
    try {
      ws = await _resolveWorkspaces(workspacesDirProvider);
    } catch (e) {
      debugPrint(
        '[kelivo_fetch] @workspaces sandbox unavailable, '
        'skipping overflow save: $e',
      );
      return null;
    }
    final name = '${_cacheKey(payload)}.${isMarkdown ? 'md' : 'txt'}';
    final dir = Directory(p.join(ws.path, '.fetch_cache'));
    try {
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsString(text);
      await _evictCache(dir, justWritten: file);
      return '@workspaces/.fetch_cache/$name';
    } catch (e) {
      debugPrint('[kelivo_fetch] overflow save failed: $e');
      return null;
    }
  }

  /// `.fetch_cache/` eviction (CONTEXT.md "Fetch temp storage"), run after
  /// every cache-dir write (overflow saves AND download temp files):
  /// 1. TTL pass: delete EVERYTHING (including `.part`/`.bak` files — crashed
  ///    downloads/installs age out) older than [cacheTtl].
  /// 2. Budget pass: delete oldest-first, excluding [justWritten] (the
  ///    current fetch's payload) and ANY file fresher than
  ///    [partGracePeriod] — a fresh file may be an in-flight parallel
  ///    download's temp, an install-phase backup, or another call's just
  ///    saved overflow file; budget eviction only trims files older than the
  ///    grace (the cache may transiently exceed the budget by an hour of
  ///    writes). Older entries are evictable regardless of extension.
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
            '[kelivo_fetch] eviction (ttl) failed for ${ent.path}: $e',
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
          debugPrint('[kelivo_fetch] eviction (stat) skipped ${ent.path}: $e');
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
            '[kelivo_fetch] eviction (budget) failed for ${e.path}: $err',
          );
        }
      }
    } catch (e) {
      debugPrint('[kelivo_fetch] eviction pass failed: $e');
    }
  }

  static String _contentForModel(String body, {required String contentType}) {
    if (_isHtml(body, contentType: contentType)) {
      return _htmlToMarkdown(body);
    }
    if (contentType.contains('application/json') ||
        contentType.contains('+json')) {
      try {
        return jsonEncode(jsonDecode(body));
      } catch (_) {}
    }
    return body.trim();
  }

  static bool _isHtml(String body, {required String contentType}) {
    if (contentType.contains('text/html') ||
        contentType.contains('application/xhtml+xml')) {
      return true;
    }
    if (contentType.isNotEmpty) return false;
    final prefix = body.length > 256 ? body.substring(0, 256) : body;
    return RegExp(
      r'<\s*(?:!doctype\s+html|html)\b',
      caseSensitive: false,
    ).hasMatch(prefix);
  }

  static String _htmlToMarkdown(String html) {
    final dom.Document document = html_parser.parse(html);
    document
        .querySelectorAll(
          'script,style,noscript,template,svg,iframe,nav,aside,footer,form',
        )
        .forEach((element) => element.remove());

    final mainContent = document.querySelector('main,article,[role="main"]');
    final source = mainContent?.outerHtml ?? document.body?.innerHtml ?? html;
    final markdown = html2md.convert(source).trim();
    if (markdown.isNotEmpty) {
      return markdown.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    }
    return (mainContent?.text ?? document.body?.text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _bounded(String text, KelivoFetchRequestPayload payload) {
    if (payload.startIndex >= text.length) {
      return 'No more content available.';
    }

    var start = payload.startIndex;
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) {
      start -= 1;
    }
    var end = math.min(start + payload.maxLength, text.length);
    if (end < text.length &&
        end > start &&
        _isHighSurrogate(text.codeUnitAt(end - 1)) &&
        _isLowSurrogate(text.codeUnitAt(end))) {
      end = end - start == 1 ? end + 1 : end - 1;
    }

    final content = text.substring(start, end);
    if (end >= text.length) return content;
    return '$content\n\n[Content truncated: showing characters $start-${end - 1} '
        'of ${text.length}. Call kelivo_fetch with start_index=$end to continue.]';
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static Map<String, dynamic> _ok(String text) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isStreaming': false,
    'isError': false,
  };

  static Map<String, dynamic> _err(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isStreaming': false,
    'isError': true,
  };
}

/// Minimal JSON-RPC server for MCP that serves @kelivo/fetch tools.
class KelivoFetchMcpServerEngine {
  bool _closed = false;

  /// Resolves the `@workspaces` sandbox for download/overflow saves.
  /// Defaults to `AppDirectories.getWorkspacesDirectory()`; injectable for
  /// tests. Resolved lazily per call — no I/O at construction time.
  final Future<Directory> Function()? workspacesDirProvider;

  KelivoFetchMcpServerEngine({this.workspacesDirProvider});

  Future<dynamic> handleMessage(dynamic message) async {
    if (_closed) return null;

    // Support batch arrays defensively (return array of responses)
    if (message is List) {
      final out = <dynamic>[];
      for (final m in message) {
        out.add(await _handleSingle(m));
      }
      return out;
    }
    return await _handleSingle(message);
  }

  Future<Map<String, dynamic>> _handleSingle(dynamic raw) async {
    try {
      if (raw is! Map) {
        return _error(null, code: -32600, message: 'Invalid Request');
      }
      final req = raw.cast<String, dynamic>();
      final id = req['id'];
      final method = (req['method'] ?? '').toString();
      final params = (req['params'] is Map)
          ? (req['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};

      switch (method) {
        case mcp.McpProtocol.methodInitialize:
          return _ok(
            id,
            result: {
              'serverInfo': {'name': '@kelivo/fetch', 'version': '1.2.0'},
              'protocolVersion': mcp.McpProtocol.defaultVersion,
              // Only tools capability is advertised for this minimal server
              'capabilities': {
                'tools': {'listChanged': false},
              },
            },
          );

        case mcp.McpProtocol.methodListTools:
          return _ok(id, result: {'tools': _toolDefinitions()});

        case mcp.McpProtocol.methodCallTool:
          final name = (params['name'] ?? '').toString();
          final arguments = (params['arguments'] is Map)
              ? (params['arguments'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};

          KelivoFetchRequestPayload payload;
          try {
            payload = KelivoFetchRequestPayload.parse(arguments);
          } catch (e) {
            return _ok(id, result: KelivoFetcher._err(e.toString()));
          }

          if (name == 'kelivo_fetch') {
            return _ok(
              id,
              result: await KelivoFetcher.fetch(
                payload,
                workspacesDirProvider: workspacesDirProvider,
              ),
            );
          }
          return _error(id, code: -32101, message: 'Tool not found: $name');

        default:
          // Ignore common notifications; respond error for unknown requests
          if (id == null) {
            return _noop();
          }
          return _error(id, code: -32601, message: 'Method not found: $method');
      }
    } catch (e) {
      return _error(null, code: -32603, message: 'Internal error: $e');
    }
  }

  void close() {
    _closed = true;
  }

  Map<String, dynamic> _ok(dynamic id, {required Map<String, dynamic> result}) {
    return {'jsonrpc': '2.0', if (id != null) 'id': id, 'result': result};
  }

  Map<String, dynamic> _error(
    dynamic id, {
    required int code,
    required String message,
  }) {
    return {
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  Map<String, dynamic> _noop() => {'jsonrpc': '2.0'};

  List<Map<String, dynamic>> _toolDefinitions() {
    Map<String, dynamic> schema() => {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description':
              'Use the URL exactly as given; do not add www. It must include '
              'http:// or https://: https://example.com is valid, while '
              'example.com is invalid.',
        },
        'headers': {
          'type': 'object',
          'description': 'Optional headers to include in the request',
        },
        'max_length': {
          'type': 'integer',
          'description': 'Maximum content characters to return',
          'default': KelivoFetchRequestPayload.defaultMaxLength,
          'minimum': 1,
          'maximum': KelivoFetchRequestPayload.maximumMaxLength,
        },
        'start_index': {
          'type': 'integer',
          'description': 'Character index used to continue truncated content',
          'default': 0,
          'minimum': 0,
        },
        'raw': {
          'type': 'boolean',
          'description':
              'Return raw source instead of compact, readable Markdown',
          'default': false,
        },
        'download_path': {
          'type': 'string',
          'description':
              'Optional full file path under @workspaces/ (e.g. '
              '@workspaces/reports/q3.pdf) that saves the fetched bytes '
              'as-is — binary content included. Must be a complete file '
              'path, not a directory; existing files are silently '
              'overwritten. When set, the response is a save confirmation '
              '(path + byte size) and max_length, start_index and raw are '
              'ignored.',
        },
      },
      'required': ['url'],
    };

    return [
      {
        'name': 'kelivo_fetch',
        'description':
            'Fetch the public contents of a web page. Only fetch a URL that '
            'already appears in the conversation: one provided by the user or '
            'returned by a prior web_search, kelivo_fetch, or other tool. '
            'Cannot access content that requires authentication, including private '
            'documents or pages behind login walls. HTML is simplified to compact '
            'Markdown with bounded output by default. Continue truncated content with '
            'start_index; use raw=true only when exact source is required. '
            'When content exceeds max_length, the full content is saved to '
            '@workspaces/.fetch_cache/ and the path is returned. Use '
            'download_path to save any content as-is (binary included).',
        'inputSchema': schema(),
      },
    ];
  }
}

/// In-memory ClientTransport that directly invokes the local server engine.
class KelivoInMemoryClientTransport implements mcp.ClientTransport {
  final KelivoFetchMcpServerEngine _server;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  bool _closed = false;

  KelivoInMemoryClientTransport(this._server);

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    if (_closed) return;
    // Process asynchronously to mimic real transport
    Future.microtask(() async {
      final resp = await _server.handleMessage(message);
      if (_closed) return;
      if (resp != null) {
        _messageController.add(resp);
      }
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _server.close();
    } catch (_) {}
    if (!_messageController.isClosed) _messageController.close();
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}
