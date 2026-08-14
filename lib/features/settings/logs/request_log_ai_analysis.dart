import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import 'request_log_parser.dart';

/// Creates a privacy-scrubbed, AI-readable export of request-log entries.
class RequestLogAiAnalysisExporter {
  RequestLogAiAnalysisExporter._();

  static const int _maxStringCharacters = 8192;
  static const int _retainedCharactersPerSide = 2048;

  static const Set<String> _exactSensitiveNames = <String>{
    'authorization',
    'proxyauthorization',
    'apikey',
    'xapikey',
    'xgoogapikey',
    'accesskey',
    'privatekey',
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'bearer',
    'secret',
    'clientsecret',
    'password',
    'cookie',
    'setcookie',
    'session',
    'sessionid',
    'signature',
    'credential',
    'credentials',
  };

  /// Writes [entries] as a regular text attachment so it remains available
  /// if the user later sends the prefilled draft. Files live under the app
  /// cache (not the upload tree) so they never enter backups or LAN sync;
  /// any previously staged analysis file is removed first so the directory
  /// holds at most the newest draft.
  static Future<File> writeAnalysisFile({
    required List<RequestLogEntry> entries,
    required String fileNamePrefix,
  }) async {
    if (entries.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'must not be empty');
    }

    final cacheDirectory = await AppDirectories.getCacheDirectory();
    final outputDirectory = Directory(
      p.join(cacheDirectory.path, 'request-log-analysis'),
    );
    if (!await outputDirectory.exists()) {
      await outputDirectory.create(recursive: true);
    } else {
      await _removeStaleAnalysisFiles(outputDirectory);
    }

    final now = DateTime.now().toUtc();
    final timestamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final prefix = _safeFileNamePrefix(fileNamePrefix);
    final file = File(
      p.join(outputDirectory.path, '${prefix}_$timestamp.json'),
    );
    final text = const JsonEncoder.withIndent('  ').convert(
      buildPayload(entries, generatedAt: now),
    );
    await file.writeAsString(text, flush: true);
    return file;
  }

  /// Removes previously staged analysis drafts. A previous draft is either
  /// already sent (the message carries its content) or was abandoned, so
  /// keeping only the newest file bounds the cache to a single entry and
  /// prevents orphaned JSON from accumulating on disk.
  static Future<void> _removeStaleAnalysisFiles(Directory directory) async {
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.json')) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Produces the export payload without doing file I/O.
  static Map<String, dynamic> buildPayload(
    List<RequestLogEntry> entries, {
    DateTime? generatedAt,
  }) {
    final timestamp = generatedAt ?? DateTime.now().toUtc();
    return <String, dynamic>{
      'format': 'cuplivo.request-log-ai-analysis.v1',
      'generated_at': timestamp.toIso8601String(),
      'request_count': entries.length,
      'requests': entries.map(_entryToPayload).toList(growable: false),
    };
  }

  static Map<String, dynamic> _entryToPayload(RequestLogEntry entry) {
    return <String, dynamic>{
      'id': entry.id,
      'category': entry.category,
      'started_at': entry.startedAt?.toIso8601String(),
      'last_event_at': entry.lastEventAt?.toIso8601String(),
      'duration_ms': entry.duration?.inMilliseconds,
      'method': entry.method,
      'url': _redactUrl(entry.rawUrl),
      'request_headers': _transformJsonValue(entry.requestHeaders),
      'request_body': _transformBody(entry.requestBody),
      'status_code': entry.statusCode,
      'response_headers': _transformJsonValue(entry.responseHeaders),
      'response_body': _transformBody(entry.responseBody),
      'errors': List<String>.of(entry.errors),
      'warnings': List<String>.of(entry.warnings),
    };
  }

  /// Parses a body only when it is JSON. Any parsing or transformation issue
  /// leaves the body untouched, as a plain string, so a malformed provider
  /// payload can never break the log viewer action.
  static Object? _transformBody(String? body) {
    if (body == null) return null;
    try {
      return _transformJsonValue(jsonDecode(body));
    } catch (error, stackTrace) {
      debugPrint(
        'RequestLogAiAnalysisExporter: keeping non-JSON body unchanged: '
        '$error\n$stackTrace',
      );
      return body;
    }
  }

  static Object? _transformJsonValue(Object? value, {String? fieldName}) {
    if (fieldName != null && _isSensitiveName(fieldName)) {
      return '<REDACTED: $fieldName>';
    }
    if (value is Map) {
      final transformed = <String, dynamic>{};
      value.forEach((key, nestedValue) {
        final name = key.toString();
        transformed[name] = _transformJsonValue(
          nestedValue,
          fieldName: name,
        );
      });
      return transformed;
    }
    if (value is List) {
      return value
          .map<Object?>((item) => _transformJsonValue(item))
          .toList(growable: false);
    }
    if (value is String) {
      return _truncateLongString(value);
    }
    return value;
  }

  static String? _redactUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.isEmpty) return rawUrl;

    final queryStart = rawUrl.indexOf('?');
    if (queryStart < 0) return rawUrl;

    final fragmentStart = rawUrl.indexOf('#', queryStart + 1);
    final queryEnd = fragmentStart < 0 ? rawUrl.length : fragmentStart;
    final beforeQuery = rawUrl.substring(0, queryStart + 1);
    final rawQuery = rawUrl.substring(queryStart + 1, queryEnd);
    final fragment = fragmentStart < 0 ? '' : rawUrl.substring(fragmentStart);

    final sanitizedQuery = rawQuery
        .split('&')
        .map(_redactQuerySegment)
        .join('&');
    return '$beforeQuery$sanitizedQuery$fragment';
  }

  static String _redactQuerySegment(String segment) {
    if (segment.isEmpty) return segment;

    final separator = segment.indexOf('=');
    final rawName = separator < 0 ? segment : segment.substring(0, separator);
    final decodedName = _decodeQueryName(rawName);
    if (!_isSensitiveName(decodedName)) return segment;

    final placeholder = '<REDACTED: $decodedName>';
    if (separator < 0) return '$rawName=$placeholder';
    return '${segment.substring(0, separator + 1)}$placeholder';
  }

  static String _decodeQueryName(String rawName) {
    try {
      return Uri.decodeQueryComponent(rawName);
    } catch (error, stackTrace) {
      debugPrint(
        'RequestLogAiAnalysisExporter: could not decode query name: '
        '$error\n$stackTrace',
      );
      return rawName;
    }
  }

  static bool _isSensitiveName(String name) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (normalized.isEmpty) return false;
    if (_exactSensitiveNames.contains(normalized)) return true;

    return normalized.endsWith('key') ||
        normalized.endsWith('accesstoken') ||
        normalized.endsWith('refreshtoken') ||
        normalized.endsWith('idtoken') ||
        normalized.endsWith('token') ||
        normalized.endsWith('clientsecret') ||
        normalized.endsWith('secret') ||
        normalized.endsWith('password') ||
        normalized.endsWith('cookie') ||
        normalized.endsWith('sessionid') ||
        normalized.endsWith('signature') ||
        normalized.endsWith('credential') ||
        normalized.endsWith('credentials');
  }

  static String _truncateLongString(String value) {
    if (value.length <= _maxStringCharacters) return value;

    final omittedCharacters =
        value.length - (_retainedCharactersPerSide * 2);
    final head = value.substring(0, _retainedCharactersPerSide);
    final tail = value.substring(value.length - _retainedCharactersPerSide);
    return '$head\n<TRUNCATED: $omittedCharacters characters omitted>\n$tail';
  }

  static String _safeFileNamePrefix(String value) {
    final trimmed = value.trim();
    final base = trimmed.isEmpty ? 'request-log-analysis' : trimmed;
    return base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
  }
}
