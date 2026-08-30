import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Serves the bundled Web chat shell from a loopback HTTP origin so Darwin
/// (iOS/macOS) WKWebView never uses a `file://` document origin (ADR-0051).
/// Windows uses a WebView2 HTTPS virtual host and Android uses
/// `appassets.androidplatform.net`; this server closes the last gap.
///
/// Process-level lazy singleton: once acquired it serves for the lifetime of
/// the process and is never stopped. The port is ephemeral and re-bound fresh
/// on each launch, so no port is reused across runs.
final class LocalWebChatShellServer {
  LocalWebChatShellServer._(this._server);

  static LocalWebChatShellServer? _instance;
  static Future<LocalWebChatShellServer>? _startup;

  final HttpServer _server;

  /// A strict allowlist: the whole bundled shell tree plus mermaid, which the
  /// shell loads as `../mermaid.min.js` from `assets/web_chat/app.mjs`.
  static const String _shellTreePrefix = 'assets/web_chat/';
  static const String _mermaidAssetKey = 'assets/mermaid.min.js';

  int get port => _server.port;

  Uri get shellUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/assets/web_chat/index.html',
  );

  /// Idempotent: always returns the one process-wide server. A failed start
  /// clears the pending future so a later retry can bind again.
  static Future<LocalWebChatShellServer> acquire() {
    final existing = _instance;
    if (existing != null) return Future.value(existing);
    final pending = _startup;
    if (pending != null) return pending;
    final future = _start();
    _startup = future;
    future.then(
      (server) {
        if (identical(_startup, future)) _instance = server;
      },
      onError: (Object error) {
        if (identical(_startup, future)) _startup = null;
        debugPrint(
          'LocalWebChatShellServer: start failed (${error.runtimeType})',
        );
      },
    );
    return future;
  }

  static Future<LocalWebChatShellServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = LocalWebChatShellServer._(server);
    server.listen(
      (request) => unawaited(instance._serve(request)),
      onError: (Object error) {
        debugPrint(
          'LocalWebChatShellServer: connection error (${error.runtimeType})',
        );
      },
    );
    return instance;
  }

  /// Whether [uri] addresses this server with a whitelisted shell path. Used
  /// by the WebView navigation delegate so the shell itself is allowed while
  /// any other loopback URL falls through to the external browser. Only the
  /// literal `127.0.0.1` host matches — the server binds IPv4 loopback only,
  /// and on Darwin `localhost` may resolve to `::1` first.
  bool isLocalShellUri(Uri uri) {
    if (uri.scheme != 'http') return false;
    if (uri.host != '127.0.0.1') return false;
    if (uri.port != port) return false;
    return assetKeyForPath(uri.path) != null;
  }

  /// Resolves a raw URL path to an asset key, or null when the path escapes
  /// the allowlist. `Uri.path` is percent-encoded, so the path is decoded
  /// *before* segment validation — literal and encoded `..`/dot segments are
  /// both rejected at the boundary instead of falling through to the asset
  /// lookup, and malformed escapes are rejected outright.
  static String? assetKeyForPath(String rawPath) {
    if (rawPath.contains('\u0000')) return null;
    final String decoded;
    try {
      decoded = Uri.decodeFull(rawPath);
    } on ArgumentError {
      return null;
    }
    final normalized = decoded.replaceAll('\\', '/');
    if (!normalized.startsWith('/')) return null;
    final segments = normalized.split('/');
    if (segments.any((segment) => segment == '..' || segment == '.')) {
      return null;
    }
    final key = normalized.substring(1);
    if (!key.startsWith(_shellTreePrefix) && key != _mermaidAssetKey) {
      return null;
    }
    return key;
  }

  static String contentTypeForKey(String key) {
    final extension = key.split('.').last.toLowerCase();
    return switch (extension) {
      'html' || 'htm' => 'text/html; charset=utf-8',
      'css' => 'text/css; charset=utf-8',
      'js' || 'mjs' => 'text/javascript; charset=utf-8',
      'json' || 'map' => 'application/json; charset=utf-8',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'woff' => 'font/woff',
      'woff2' => 'font/woff2',
      'ttf' => 'font/ttf',
      'otf' => 'font/otf',
      'ico' => 'image/x-icon',
      'txt' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _respond(
          request,
          HttpStatus.methodNotAllowed,
          'method not allowed',
        );
        return;
      }
      final key = assetKeyForPath(request.uri.path);
      if (key == null) {
        await _respond(request, HttpStatus.notFound, 'not found');
        return;
      }
      final data = await rootBundle.load(key);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final headers = request.response.headers;
      headers.set(HttpHeaders.contentTypeHeader, contentTypeForKey(key));
      headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      headers.set(HttpHeaders.contentLengthHeader, bytes.length);
      request.response.statusCode = HttpStatus.ok;
      if (request.method == 'HEAD') {
        await request.response.close();
      } else {
        request.response.add(bytes);
        await request.response.close();
      }
    } catch (error) {
      debugPrint(
        'LocalWebChatShellServer: request failed (${error.runtimeType})',
      );
      await _respond(request, HttpStatus.notFound, 'not found');
    }
  }

  Future<void> _respond(HttpRequest request, int status, String body) async {
    try {
      final response = request.response;
      response.statusCode = status;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/plain; charset=utf-8',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.write(body);
      await response.close();
    } catch (error) {
      debugPrint(
        'LocalWebChatShellServer: response failed (${error.runtimeType})',
      );
    }
  }
}
