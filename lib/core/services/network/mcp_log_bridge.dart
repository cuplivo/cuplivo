import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;

import 'request_logger.dart';

/// App-side sink for the vendored `mcp_client` JSON-RPC-layer log
/// events. Formats `[MCP REQ n]` / `[MCP RES n]` lines, allocates
/// globally unique log ids (the request-log viewer keys entries by id,
/// and per-client JSON-RPC ids repeat across servers), applies
/// write-time suppression of repeated failures (per server, deduped by
/// `code|message`, capped at 20 distinct entries), and flushes a
/// one-line summary on recovery, disconnect, or cap overflow.
///
/// Successful heartbeat calls (tagged `reason: heartbeat`) are
/// suppressed entirely; heartbeat failures are logged, except
/// rate-limit failures (the app treats those as "server alive").
class McpLogBridge {
  McpLogBridge._();

  static const int _maxSuppressedPerServer = 20;
  static const int _maxLineChars = 64 * 1024;
  static const String _heartbeatTag = 'heartbeat';

  /// label → JSON-RPC id → allocated log id.
  static final Map<String, Map<dynamic, int>> _pending =
      <String, Map<dynamic, int>>{};

  /// label → JSON-RPC id → buffered (unlogged) heartbeat request line.
  static final Map<String, Map<dynamic, String>> _heartbeatReqLines =
      <String, Map<dynamic, String>>{};

  /// label → dedupe key (`code|message`) → repeat count.
  static final Map<String, Map<String, int>> _suppressed =
      <String, Map<String, int>>{};

  /// label → when suppression started for that server.
  static final Map<String, DateTime> _suppressedSince = <String, DateTime>{};

  /// Test hook: replaces the write destination (normally
  /// [RequestLogger.logLine]). When set, emitted lines are handed here
  /// instead. Null restores the default sink.
  @visibleForTesting
  static void Function(String line)? logSinkOverride;

  /// Test hook: clears all per-server state (pending pairing,
  /// heartbeat buffers, suppression sets).
  @visibleForTesting
  static void resetForTesting() {
    _pending.clear();
    _heartbeatReqLines.clear();
    _suppressed.clear();
    _suppressedSince.clear();
  }

  /// Entry point wired into `McpClientConfig.logListener`.
  static void onEvent(mcp.McpLogEvent e) {
    if (!RequestLogger.categoryEnabled(RequestLogger.catMcp)) return;
    try {
      _handle(e);
    } catch (err, st) {
      debugPrint('[McpLogBridge] failed to process event: $err\n$st');
    }
  }

  static void _handle(mcp.McpLogEvent e) {
    final label = e.server;
    switch (e.kind) {
      case 'request':
        _onRequest(e, label);
      case 'notification':
        _onNotification(e, label);
      case 'response':
        if (e.direction == 'send') {
          _onResponseSent(e, label);
        } else {
          _onResponseReceived(e, label);
        }
      case 'error-response':
        if (e.direction == 'send') {
          _onErrorSent(e, label);
        } else {
          _onErrorReceived(e, label);
        }
      case 'lifecycle':
        _logLine('[MCP LIFE] $label ${e.payload}');
        if (e.payload == 'disconnected') {
          _flushSuppressed(label, reason: 'disconnect');
          _pending.remove(label);
          _heartbeatReqLines.remove(label);
        }
    }
  }

  static void _onRequest(mcp.McpLogEvent e, String label) {
    final logId = RequestLogger.nextRequestId();
    final method = e.method ?? '?';
    final line = '[MCP REQ $logId] method=$method body=${_payload(e.payload)}';
    _pending.putIfAbsent(label, () => <dynamic, int>{})[e.id] = logId;
    if (e.tags?['reason'] == _heartbeatTag) {
      // Defer: the exchange is only logged when it fails.
      _heartbeatReqLines.putIfAbsent(label, () => <dynamic, String>{})[e.id] =
          line;
    } else {
      _logLine(line);
    }
  }

  static void _onNotification(mcp.McpLogEvent e, String label) {
    final method = e.method ?? '?';
    if (e.direction == 'send') {
      final logId = RequestLogger.nextRequestId();
      _logLine('[MCP REQ $logId] method=$method body=${_payload(e.payload)}');
    } else {
      final logId = RequestLogger.nextRequestId();
      _logLine('[MCP RES $logId] method=$method body=${_payload(e.payload)}');
      // A server-sent notification proves the server is alive.
      _flushIfSuppressed(label, reason: 'recovered');
    }
  }

  static void _onResponseReceived(mcp.McpLogEvent e, String label) {
    final logId = _takeLogId(label, e.id);
    final method = e.method ?? '?';
    _flushIfSuppressed(label, reason: 'recovered');
    if (e.tags?['reason'] == _heartbeatTag) {
      _dropHeartbeatReqLine(label, e.id);
      return;
    }
    final gated = !RequestLogger.saveOutput && _isListMethod(method);
    final result = gated ? '<omitted (saveOutput off)>' : _payload(e.payload);
    _logLine('[MCP RES $logId] method=$method result=$result');
  }

  static void _onResponseSent(mcp.McpLogEvent e, String label) {
    final logId = _takeLogId(label, e.id);
    final method = e.method ?? '?';
    final gated = !RequestLogger.saveOutput && _isListMethod(method);
    final result = gated ? '<omitted (saveOutput off)>' : _payload(e.payload);
    _logLine('[MCP RES $logId] method=$method result=$result');
  }

  static void _onErrorSent(mcp.McpLogEvent e, String label) {
    final logId = _takeLogId(label, e.id);
    final method = e.method ?? '?';
    _logLine('[MCP RES $logId] method=$method error=${_payload(e.payload)}');
  }

  static void _onErrorReceived(mcp.McpLogEvent e, String label) {
    final logId = _takeLogId(label, e.id);
    final method = e.method ?? '?';
    final errorPayload = e.payload;
    final code = errorPayload is Map ? errorPayload['code'] : null;
    final message = errorPayload is Map
        ? (errorPayload['message']?.toString() ?? '')
        : errorPayload?.toString() ?? '';

    if (e.tags?['reason'] == _heartbeatTag) {
      final buffered = _heartbeatReqLines[label]?.remove(e.id);
      if (_isRateLimit(code, message)) {
        return; // Server alive per app semantics — suppress entirely.
      }
      if (buffered != null) _logLine(buffered);
      _logLine('[MCP RES $logId] method=$method error=${_payload(e.payload)}');
      return;
    }

    final key = '$code|${message.trim()}';
    final suppressed = _suppressed[label];
    if (suppressed != null && suppressed.containsKey(key)) {
      suppressed[key] = suppressed[key]! + 1;
      return;
    }
    if (suppressed != null && suppressed.length >= _maxSuppressedPerServer) {
      _flushSuppressed(label, reason: 'cap');
    }
    _suppressedSince.putIfAbsent(label, () => DateTime.now());
    _suppressed.putIfAbsent(label, () => <String, int>{})[key] = 0;
    _logLine('[MCP RES $logId] method=$method error=${_payload(e.payload)}');
  }

  static bool _isRateLimit(Object? code, String message) {
    if (code == -32106) return true;
    final msg = message.toLowerCase();
    return msg.contains('429') || msg.contains('rate limit');
  }

  static bool _isListMethod(String method) =>
      method.endsWith('/list') || method == 'roots/list';

  static int _takeLogId(String label, dynamic rpcId) {
    final logId = _pending[label]?.remove(rpcId);
    return logId ?? RequestLogger.nextRequestId();
  }

  static void _dropHeartbeatReqLine(String label, dynamic rpcId) {
    _heartbeatReqLines[label]?.remove(rpcId);
  }

  static void _flushIfSuppressed(String label, {required String reason}) {
    if ((_suppressed[label]?.isEmpty ?? true)) return;
    _flushSuppressed(label, reason: reason);
  }

  static void _flushSuppressed(String label, {required String reason}) {
    final entries = _suppressed.remove(label);
    if (entries == null || entries.isEmpty) return;
    final since = _suppressedSince.remove(label) ?? DateTime.now();
    final repeats = entries.values.fold<int>(0, (acc, n) => acc + n);
    final keys = entries.entries
        .map((e) => e.value > 0 ? '${e.key}(x${e.value})' : e.key)
        .join('; ');
    _logLine(
      '[MCP WARN] $label suppressed $repeats repeated errors '
      '(${entries.length} distinct) since ${_fmtTs(since)} '
      '[$reason]: $keys',
    );
  }

  static String _fmtTs(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}.'
        '${three(dt.millisecond)}';
  }

  static String _payload(Object? payload) {
    final text = payload == null
        ? ''
        : RequestLogger.escape(RequestLogger.encodeObject(payload));
    if (text.length <= _maxLineChars) return text;
    return '${text.substring(0, _maxLineChars)} [truncated]';
  }

  static void _logLine(String line) {
    final override = logSinkOverride;
    if (override != null) {
      override(line);
      return;
    }
    RequestLogger.logLine(line, category: RequestLogger.catMcp);
  }
}
