import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'request_logger.dart';

/// Log categories served by [LoggingHttpClient].
enum LoggingCategory { tts, search }

/// An [http.BaseClient] wrapper that logs every request through
/// [RequestLogger] with a category tag:
///
/// - `[TTS REQ n]` / `[TTS RES n]` — request body always logged; success
///   response body never logged (all TTS providers return audio — raw or
///   base64-in-JSON, which a content-type rule alone cannot catch);
///   error response bodies always logged.
/// - `[SRCH REQ n]` / `[SRCH RES n]` — standard HTTP logging; response
///   bodies respect the global [RequestLogger.saveOutput] gate.
///
/// A binary content-type (`audio/*`, `image/*`, `video/*`,
/// `application/octet-stream`) acts as a generic safety net that skips
/// response body logging for any category.
class LoggingHttpClient extends http.BaseClient {
  LoggingHttpClient._(this._category);

  static final Map<LoggingCategory, LoggingHttpClient> _instances =
      <LoggingCategory, LoggingHttpClient>{};

  /// Shared per-category instance.
  static LoggingHttpClient of(LoggingCategory category) =>
      _instances.putIfAbsent(category, () => LoggingHttpClient._(category));

  static const int _maxBodyBytes = 64 * 1024;

  final LoggingCategory _category;
  final http.Client _inner = http.Client();

  static String _tag(LoggingCategory c) => switch (c) {
    LoggingCategory.tts => 'TTS',
    LoggingCategory.search => 'SRCH',
  };

  static String _categoryName(LoggingCategory c) => switch (c) {
    LoggingCategory.tts => RequestLogger.catTts,
    LoggingCategory.search => RequestLogger.catSearch,
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final tag = _tag(_category);
    final categoryName = _categoryName(_category);
    final reqId = RequestLogger.nextRequestId();
    final enabled = RequestLogger.categoryEnabled(categoryName);

    http.BaseRequest wireRequest = request;
    if (enabled) {
      Uint8List bodyBytes;
      try {
        bodyBytes = await request.finalize().toBytes();
      } catch (_) {
        bodyBytes = Uint8List(0);
      }

      RequestLogger.logLine(
        '[$tag REQ $reqId] ${request.method.toUpperCase()} ${request.url}',
        category: categoryName,
      );
      if (request.headers.isNotEmpty) {
        RequestLogger.logLine(
          '[$tag REQ $reqId] headers='
          '${RequestLogger.encodeObject(RequestLogger.redactHeaders(request.headers))}',
          category: categoryName,
        );
      }
      if (bodyBytes.isNotEmpty) {
        final decoded = RequestLogger.safeDecodeUtf8(bodyBytes);
        final bodyText = decoded.isNotEmpty
            ? decoded
            : 'base64:${base64Encode(bodyBytes)}';
        RequestLogger.logLine(
          '[$tag REQ $reqId] body=${RequestLogger.escape(bodyText)}',
          category: categoryName,
        );
      }

      final clone = http.StreamedRequest(request.method, request.url)
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..contentLength = bodyBytes.isEmpty ? null : bodyBytes.length;
      clone.headers.addAll(request.headers);
      if (bodyBytes.isNotEmpty) {
        clone.sink.add(bodyBytes);
      }
      clone.sink.close();
      wireRequest = clone;
    }

    http.StreamedResponse response;
    try {
      response = await _inner.send(wireRequest);
    } catch (e) {
      if (enabled) {
        RequestLogger.logLine(
          '[$tag RES $reqId] error=${RequestLogger.escape(e.toString())}',
          category: categoryName,
        );
      }
      rethrow;
    }

    if (!enabled) {
      return response;
    }

    final statusCode = response.statusCode;
    RequestLogger.logLine(
      '[$tag RES $reqId] status=$statusCode',
      category: categoryName,
    );
    if (response.headers.isNotEmpty) {
      RequestLogger.logLine(
        '[$tag RES $reqId] headers='
        '${RequestLogger.encodeObject(RequestLogger.redactHeaders(response.headers))}',
        category: categoryName,
      );
    }

    final isError = statusCode >= 400;
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final isBinary =
        contentType.startsWith('audio/') ||
        contentType.startsWith('image/') ||
        contentType.startsWith('video/') ||
        contentType.contains('application/octet-stream');

    // Success bodies are only ever buffered for the search category and
    // only written when saveOutput allows. TTS success bodies (audio)
    // are never buffered. Error bodies are always buffered + written.
    final bufferBody =
        isError ||
        (_category == LoggingCategory.search && RequestLogger.saveOutput);
    final logBodyOnDone = bufferBody && !isBinary;

    final body = BytesBuilder(copy: false);
    final transformed = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (data, sink) {
          if (bufferBody) {
            final remaining = _maxBodyBytes - body.length;
            if (remaining > 0) {
              body.add(data.take(remaining).toList());
            }
          }
          sink.add(data);
        },
        handleError: (e, st, sink) {
          RequestLogger.logLine(
            '[$tag RES $reqId] error=${RequestLogger.escape(e.toString())}',
            category: categoryName,
          );
          sink.addError(e, st);
        },
        handleDone: (sink) {
          if (logBodyOnDone) {
            final bytes = body.takeBytes();
            if (bytes.isNotEmpty) {
              final decoded = RequestLogger.safeDecodeUtf8(bytes);
              final bodyText = decoded.isNotEmpty
                  ? decoded
                  : 'base64:${base64Encode(bytes)}';
              var escaped = RequestLogger.escape(bodyText);
              if (bytes.length >= _maxBodyBytes) {
                escaped = '$escaped [truncated]';
              }
              RequestLogger.logLine(
                '[$tag RES $reqId] body=$escaped',
                category: categoryName,
              );
            }
          }
          sink.close();
        },
      ),
    );

    return http.StreamedResponse(
      transformed,
      statusCode,
      headers: response.headers,
    );
  }
}
