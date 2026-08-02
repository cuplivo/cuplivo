import 'dart:convert';

class RequestLogEntry {
  RequestLogEntry({
    required this.id,
    required this.sequence,
    this.category = 'llm',
    this.startedAt,
    this.lastEventAt,
    this.method,
    this.rawUrl,
    this.uri,
    this.requestHeaders,
    this.requestBody,
    this.statusCode,
    this.responseHeaders,
    this.responseBody,
    List<String>? errors,
    List<String>? warnings,
  }) : errors = errors ?? <String>[],
       warnings = warnings ?? <String>[];

  final int id;
  // Monotonic sequence to disambiguate duplicate ids across app restarts.
  final int sequence;

  /// Log category: `llm` | `mcp` | `tts` | `search`.
  final String category;

  DateTime? startedAt;
  DateTime? lastEventAt;

  String? method;
  String? rawUrl;
  Uri? uri;

  Map<String, dynamic>? requestHeaders;
  String? requestBody;

  int? statusCode;
  Map<String, dynamic>? responseHeaders;
  String? responseBody;

  final List<String> errors;
  final List<String> warnings;

  bool get hasError =>
      errors.isNotEmpty || (statusCode != null && statusCode! >= 400);
  bool get hasWarning =>
      warnings.isNotEmpty ||
      (statusCode != null && statusCode! >= 300 && statusCode! < 400);

  Duration? get duration {
    final s = startedAt;
    final e = lastEventAt;
    if (s == null || e == null) return null;
    return e.difference(s);
  }
}

class RequestLogParser {
  static final RegExp _tsRe = RegExp(
    r'^\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})\]\s+(.*)$',
  );

  static final RegExp _mcpReqRe = RegExp(
    r'^\[MCP REQ (\d+)\]\s+method=(\S+)(?:\s+body=(.*))?$',
    dotAll: true,
  );
  static final RegExp _mcpResRe = RegExp(
    r'^\[MCP RES (\d+)\]\s+method=(\S+)(?:\s+(result|error|body)=(.*))?$',
    dotAll: true,
  );

  static final RegExp _reqStartRe = RegExp(
    r'^\[(?:(\w+)\s+)?REQ (\d+)\]\s+([A-Z]+)\s+(.*)$',
    dotAll: true,
  );
  static final RegExp _reqHeadersRe = RegExp(
    r'^\[(?:(\w+)\s+)?REQ (\d+)\]\s+headers=(.*)$',
    dotAll: true,
  );
  static final RegExp _reqBodyRe = RegExp(
    r'^\[(?:(\w+)\s+)?REQ (\d+)\]\s+body=(.*)$',
    dotAll: true,
  );

  static final RegExp _resStatusRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+status=(\d+)\s*$',
    dotAll: true,
  );
  static final RegExp _resHeadersRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+headers=(.*)$',
    dotAll: true,
  );
  static final RegExp _resBodyRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+body=(.*)$',
    dotAll: true,
  );
  static final RegExp _resChunkRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+chunk=(.*)$',
    dotAll: true,
  );
  static final RegExp _resDoneRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+done\s*$',
    dotAll: true,
  );
  static final RegExp _resErrRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+error=(.*)$',
    dotAll: true,
  );
  static final RegExp _resDioErrRe = RegExp(
    r'^\[(?:(\w+)\s+)?RES (\d+)\]\s+dio_error=(.*)$',
    dotAll: true,
  );

  /// Maps a log-line tag prefix to the canonical category name.
  /// `SRCH` is the tag in the log format; the category string is `search`.
  static String _normalizeCategory(String? tag) {
    switch (tag?.toLowerCase()) {
      case null:
      case '':
      case 'llm':
        return 'llm';
      case 'mcp':
        return 'mcp';
      case 'tts':
        return 'tts';
      case 'srch':
        return 'search';
      default:
        return tag!.toLowerCase();
    }
  }

  static List<RequestLogEntry> parse(String content) {
    final records = _toRecords(content);

    final List<RequestLogEntry> entries = <RequestLogEntry>[];
    // Keyed by `category:id` — the shared request-id counter makes bare
    // ids unique across categories, but this also keeps malformed logs
    // (duplicate ids) from cross-contaminating entries.
    final Map<String, int> currentIndexById = <String, int>{};
    int seq = 0;

    RequestLogEntry ensureEntry(int id, String category) {
      final idx = currentIndexById['$category:$id'];
      if (idx != null) return entries[idx];
      final e = RequestLogEntry(id: id, sequence: ++seq, category: category);
      entries.add(e);
      currentIndexById['$category:$id'] = entries.length - 1;
      return e;
    }

    void touch(RequestLogEntry e, DateTime ts) {
      e.lastEventAt = ts;
      e.startedAt ??= ts;
    }

    for (final record in records) {
      final ts = record.ts;
      final msg = record.message;

      final mMcpReq = _mcpReqRe.firstMatch(msg);
      if (mMcpReq != null) {
        final id = int.tryParse(mMcpReq.group(1) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, 'mcp');
        touch(e, ts);
        e.method = (mMcpReq.group(2) ?? '').trim();
        final body = (mMcpReq.group(3) ?? '').trim();
        if (body.isNotEmpty) e.requestBody = unescape(body);
        continue;
      }

      final mMcpRes = _mcpResRe.firstMatch(msg);
      if (mMcpRes != null) {
        final id = int.tryParse(mMcpRes.group(1) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, 'mcp');
        touch(e, ts);
        e.method = (mMcpRes.group(2) ?? '').trim();
        final kind = mMcpRes.group(3);
        final value = (mMcpRes.group(4) ?? '').trim();
        if (kind == 'error') {
          if (value.isNotEmpty) e.errors.add(unescape(value));
        } else if (value.isNotEmpty) {
          e.responseBody = unescape(value);
        }
        continue;
      }

      final mStart = _reqStartRe.firstMatch(msg);
      if (mStart != null) {
        final id = int.tryParse(mStart.group(2) ?? '');
        if (id == null) continue;

        final e = RequestLogEntry(
          id: id,
          sequence: ++seq,
          category: _normalizeCategory(mStart.group(1)),
        );
        e.startedAt = ts;
        e.lastEventAt = ts;
        e.method = (mStart.group(3) ?? '').trim();
        final url = (mStart.group(4) ?? '').trim();
        e.rawUrl = url;
        e.uri = Uri.tryParse(url);
        entries.add(e);
        currentIndexById['${e.category}:$id'] = entries.length - 1;
        continue;
      }

      final mReqHeaders = _reqHeadersRe.firstMatch(msg);
      if (mReqHeaders != null) {
        final id = int.tryParse(mReqHeaders.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mReqHeaders.group(1)));
        touch(e, ts);
        final jsonText = (mReqHeaders.group(3) ?? '').trim();
        e.requestHeaders = _decodeJsonMap(jsonText);
        if (e.requestHeaders == null && jsonText.isNotEmpty) {
          e.warnings.add('Failed to parse request headers JSON');
        }
        continue;
      }

      final mReqBody = _reqBodyRe.firstMatch(msg);
      if (mReqBody != null) {
        final id = int.tryParse(mReqBody.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mReqBody.group(1)));
        touch(e, ts);
        e.requestBody = unescape((mReqBody.group(3) ?? '').trim());
        continue;
      }

      final mStatus = _resStatusRe.firstMatch(msg);
      if (mStatus != null) {
        final id = int.tryParse(mStatus.group(2) ?? '');
        final code = int.tryParse(mStatus.group(3) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mStatus.group(1)));
        touch(e, ts);
        e.statusCode = code;
        continue;
      }

      final mResHeaders = _resHeadersRe.firstMatch(msg);
      if (mResHeaders != null) {
        final id = int.tryParse(mResHeaders.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mResHeaders.group(1)));
        touch(e, ts);
        final jsonText = (mResHeaders.group(3) ?? '').trim();
        e.responseHeaders = _decodeJsonMap(jsonText);
        if (e.responseHeaders == null && jsonText.isNotEmpty) {
          e.warnings.add('Failed to parse response headers JSON');
        }
        continue;
      }

      final mBody = _resBodyRe.firstMatch(msg);
      if (mBody != null) {
        final id = int.tryParse(mBody.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mBody.group(1)));
        touch(e, ts);
        e.responseBody = unescape((mBody.group(3) ?? '').trim());
        continue;
      }

      final mChunk = _resChunkRe.firstMatch(msg);
      if (mChunk != null) {
        final id = int.tryParse(mChunk.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mChunk.group(1)));
        touch(e, ts);
        final chunk = unescape(mChunk.group(3) ?? '');
        final prev = e.responseBody ?? '';
        e.responseBody = prev + chunk;
        continue;
      }

      final mDone = _resDoneRe.firstMatch(msg);
      if (mDone != null) {
        final id = int.tryParse(mDone.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mDone.group(1)));
        touch(e, ts);
        continue;
      }

      final mErr = _resErrRe.firstMatch(msg);
      if (mErr != null) {
        final id = int.tryParse(mErr.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mErr.group(1)));
        touch(e, ts);
        final err = unescape((mErr.group(3) ?? '').trim());
        if (err.isNotEmpty) e.errors.add(err);
        continue;
      }

      final mDioErr = _resDioErrRe.firstMatch(msg);
      if (mDioErr != null) {
        final id = int.tryParse(mDioErr.group(2) ?? '');
        if (id == null) continue;
        final e = ensureEntry(id, _normalizeCategory(mDioErr.group(1)));
        touch(e, ts);
        final err = unescape((mDioErr.group(3) ?? '').trim());
        if (err.isNotEmpty) e.errors.add(err);
        continue;
      }
    }

    // Newest first (when possible)
    entries.sort((a, b) {
      final at = a.startedAt ?? a.lastEventAt;
      final bt = b.startedAt ?? b.lastEventAt;
      if (at == null && bt == null) return b.sequence.compareTo(a.sequence);
      if (at == null) return 1;
      if (bt == null) return -1;
      final c = bt.compareTo(at);
      if (c != 0) return c;
      return b.sequence.compareTo(a.sequence);
    });

    return entries;
  }

  static List<_LogRecord> _toRecords(String content) {
    final List<_LogRecord> out = <_LogRecord>[];
    final lines = content.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.trimRight();
      if (line.isEmpty && out.isEmpty) continue;

      final m = _tsRe.firstMatch(line);
      if (m != null) {
        final ts = _parseTs(m);
        final msg = m.group(8) ?? '';
        out.add(_LogRecord(ts: ts, message: msg));
        continue;
      }

      if (out.isEmpty) continue;
      out.last.message += '\n$line';
    }
    return out;
  }

  static DateTime _parseTs(RegExpMatch m) {
    int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6), g(7));
  }

  static Map<String, dynamic>? _decodeJsonMap(String text) {
    try {
      final v = jsonDecode(text);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) {
        return v.map((k, val) => MapEntry(k.toString(), val));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Reverses `RequestLogger.escape()` (handles `\\`, `\\r`, `\\n`, `\\t`).
  static String unescape(String input) {
    if (input.isEmpty) return input;
    final sb = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '\\' && i + 1 < input.length) {
        final next = input[i + 1];
        switch (next) {
          case 'n':
            sb.write('\n');
            i++;
            continue;
          case 'r':
            sb.write('\r');
            i++;
            continue;
          case 't':
            sb.write('\t');
            i++;
            continue;
          case '\\':
            sb.write('\\');
            i++;
            continue;
          default:
            // Preserve unknown escape as-is.
            sb.write('\\');
            continue;
        }
      }
      sb.write(ch);
    }
    return sb.toString();
  }
}

class _LogRecord {
  _LogRecord({required this.ts, required this.message});
  final DateTime ts;
  String message;
}
