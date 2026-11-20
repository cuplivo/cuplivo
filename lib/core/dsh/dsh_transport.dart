/// The physical carrier for one `dsh web` Host: launch-token login, the
/// authority-bound session cookie, authenticated HTTP exchanges and the
/// `/api/remote.mux` WebSocket upgrade.
///
/// ## Login is the v1 browser cookie
///
/// `GET /?token=<launch token>` answers 303 with
/// `Set-Cookie: dsh-auth-<hash>=v1.<payload>.<sig>`. The same cookie
/// authenticates `/api`, the mux WebSocket **and** the official SPA (needed
/// later to host plugin pages in a WebView). The `/connect` route mints a `v2`
/// API-operator cookie that the SPA rejects, so it is deliberately not used.
///
/// The cookie is a bearer credential bound to the exact `host[:port]` the login
/// used. Every request sends that `Host` header, never an `Origin`, and no
/// cookie jar is kept: one cookie per connection.
///
/// Transport failures are typed ([DshTransportException], [DshAuthException])
/// and never leak raw `SocketException`/`HttpException`. HTTP status mapping for
/// unary calls lives in [httpStatusException], because the RPC layer owns the
/// envelope.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dsh_endpoint.dart';
import 'dsh_errors.dart';

/// Prefix of every DSH session cookie name.
const String dshAuthCookiePrefix = 'dsh-auth-';

/// The signed browser-session cookie minted by `GET /?token=<launch token>`.
///
/// Persist it in secure storage keyed by the remote id; it stays valid across
/// `dsh web` restarts that keep the same `DSH_HOME` (the signing secret lives
/// in `$DSH_HOME/.credentials.yaml`), while the launch token rotates every
/// process start.
class DshCookie {
  const DshCookie({
    required this.name,
    required this.value,
    required this.authority,
    this.expiresAt,
  });

  factory DshCookie.fromJson(Map<String, Object?> json) {
    final expires = json['expiresAt'];
    return DshCookie(
      name: json['name'] is String ? json['name']! as String : '',
      value: json['value'] is String ? json['value']! as String : '',
      authority: json['authority'] is String
          ? json['authority']! as String
          : '',
      expiresAt: expires is num
          ? DateTime.fromMillisecondsSinceEpoch(expires.toInt(), isUtc: true)
          : null,
    );
  }

  /// Parses one raw `Set-Cookie` header value. [authority] is the authority the
  /// login request was sent to (the cookie is bound to it).
  ///
  /// Throws [DshProtocolException] when the header is not a name=value pair.
  factory DshCookie.parseSetCookie(String raw, {required String authority}) {
    final first = raw.split(';').first.trim();
    final separator = first.indexOf('=');
    if (separator <= 0) {
      throw DshProtocolException('Malformed Set-Cookie header: $raw');
    }
    final name = first.substring(0, separator).trim();
    final value = first.substring(separator + 1).trim();
    DateTime? expiresAt;
    for (final attribute in raw.split(';').skip(1)) {
      final part = attribute.trim();
      final eq = part.indexOf('=');
      final key = (eq < 0 ? part : part.substring(0, eq)).trim().toLowerCase();
      final val = eq < 0 ? '' : part.substring(eq + 1).trim();
      if (key == 'max-age') {
        final seconds = int.tryParse(val);
        if (seconds != null) {
          expiresAt = DateTime.now().toUtc().add(Duration(seconds: seconds));
        }
      } else if (key == 'expires' && expiresAt == null) {
        try {
          expiresAt = HttpDate.parse(val).toUtc();
        } on FormatException {
          // A malformed Expires only loses the convenience timestamp.
        } on HttpException {
          // Same: Max-Age already covers the normal path.
        }
      }
    }
    if (name.isEmpty || value.isEmpty) {
      throw DshProtocolException('Malformed Set-Cookie header: $raw');
    }
    return DshCookie(
      name: name,
      value: value,
      authority: authority,
      expiresAt: expiresAt,
    );
  }

  /// Picks the `dsh-auth-*` cookie out of a response's `Set-Cookie` headers.
  static DshCookie? fromSetCookieHeaders(
    List<String> headers, {
    required String authority,
  }) {
    for (final raw in headers) {
      if (raw.trimLeft().startsWith(dshAuthCookiePrefix)) {
        return DshCookie.parseSetCookie(raw, authority: authority);
      }
    }
    return null;
  }

  /// `dsh-auth-<base64url(sha256(authority))>`.
  final String name;

  /// `v1.<payload>.<signature>`; opaque to the client.
  final String value;

  /// `host[:port]` the cookie is bound to; requests must send this `Host`.
  final String authority;
  final DateTime? expiresAt;

  String get header => '$name=$value';

  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'authority': authority,
    if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
  };

  @override
  String toString() =>
      'DshCookie($name for $authority, expires ${expiresAt ?? 'unknown'})';
}

/// Maps an HTTP carrier rejection to the typed client error.
///
/// Used by the RPC layer for unary calls and by the transport for login and
/// upload. 401/403 are authentication (re-pair); 404 means the endpoint is not
/// mounted on this DSH version (hide the capability); the rest are protocol or
/// transport faults.
DshException httpStatusException(
  int statusCode,
  String endpoint, {
  String body = '',
}) {
  final detail = body.trim().isEmpty ? '' : ': ${body.trim()}';
  return switch (statusCode) {
    401 => DshAuthException(
      'The DSH session expired or the launch token was rejected$detail',
      statusCode: statusCode,
    ),
    403 => DshAuthException(
      'The Host refused this address (Host/Origin trust fence)$detail',
      statusCode: statusCode,
    ),
    404 => DshUnsupportedException(endpoint),
    405 ||
    413 ||
    415 ||
    400 => DshProtocolException('HTTP $statusCode from $endpoint$detail'),
    _ => DshTransportException(
      'HTTP $statusCode from $endpoint$detail',
      retryable: statusCode >= 500,
    ),
  };
}

/// One HTTP exchange as the transport sees it (request builder + raw response).
class DshHttpRequest {
  const DshHttpRequest({
    required this.method,
    required this.uri,
    required this.authority,
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 30),
    this.followRedirects = false,
  });

  final String method;
  final Uri uri;

  /// Exact `Host` header value (the cookie/authority binding).
  final String authority;
  final Map<String, String> headers;
  final List<int>? body;
  final Duration timeout;
  final bool followRedirects;
}

class DshHttpResponse {
  const DshHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.setCookie,
    required this.body,
    this.bytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<String> setCookie;

  /// UTF-8 view of the body (JSON envelopes, error text).
  final String body;

  /// Raw response bytes when the carrier captured them (`GET /api/file`).
  ///
  /// JSON-only carriers may leave this null; use [bodyBytes] for a uniform
  /// accessor.
  final Uint8List? bytes;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  String? get contentType => headers['content-type'];

  /// Raw bytes, falling back to the UTF-8 body for carriers that only build
  /// [body].
  Uint8List get bodyBytes => bytes ?? Uint8List.fromList(utf8.encode(body));
}

/// One upgradeable WebSocket carrying decoded JSON frames.
abstract interface class DshSocket {
  /// Decoded JSON values, one per text frame. An unparseable frame fails the
  /// stream with [DshProtocolException].
  Stream<Object?> get frames;

  void send(Object? frame);

  /// Completes when the socket closes (normally or with an error).
  Future<void> get done;

  Future<void> close([int code, String? reason]);
}

/// Injectable byte-level HTTP/WebSocket client, so the transport (and the mux)
/// are unit-testable without opening a socket.
abstract interface class DshHttpClient {
  Future<DshHttpResponse> send(DshHttpRequest request);

  Future<DshSocket> upgrade(DshHttpRequest request);

  void close({bool force = false});
}

/// The carrier contract used by the RPC and mux layers. A future tunnel carrier
/// implements this same surface.
abstract interface class DshTransport {
  DshEndpoint get endpoint;
  DshCookie? get cookie;
  String get authority;
  bool get secure;

  /// `GET /?token=…` (no redirect following): captures the v1 cookie.
  Future<DshCookie> login(String token);

  /// `GET /` with the cookie; authenticates a restored or fresh pair.
  Future<void> verify();

  /// Adopts a cookie restored from secure storage.
  void useCookie(DshCookie cookie);

  /// `POST /api/<endpoint>` with the client-request envelope bytes.
  Future<DshHttpResponse> post(String endpoint, Object? envelope);

  Future<DshHttpResponse> get(Uri uri);

  Future<DshHttpResponse> postBytes(
    Uri uri,
    List<int> bytes, {
    required String contentType,
  });

  /// Upgrade `/api/remote.mux`. The cookie must be present.
  Future<DshSocket> openMux();

  Future<void> close({bool force = false});
}

/// The `dart:io` transport for one `dsh web` Host.
class DshHttpTransport implements DshTransport {
  DshHttpTransport(
    this.endpoint, {
    DshCookie? cookie,
    DshHttpClient? httpClient,
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30),
    this.pingInterval = const Duration(seconds: 15),
  }) : _http = httpClient ?? DshIoHttpClient(connectTimeout: connectTimeout) {
    _cookie = cookie;
  }

  @override
  final DshEndpoint endpoint;
  final DshHttpClient _http;
  DshCookie? _cookie;

  /// TCP/TLS connect budget (passed to the default `dart:io` client).
  final Duration connectTimeout;

  /// Default per-request budget for RPC, login and verify.
  final Duration requestTimeout;

  /// Client-side WebSocket ping cadence (the Host pings every 2 s; this is the
  /// dead-link detector in the other direction).
  final Duration pingInterval;

  @override
  DshCookie? get cookie => _cookie;

  @override
  String get authority => endpoint.authority;

  @override
  bool get secure => endpoint.secure;

  @override
  void useCookie(DshCookie cookie) {
    if (cookie.authority != endpoint.authority) {
      throw DshEndpointException(
        'This session belongs to ${cookie.authority}, not ${endpoint.authority}',
        field: 'url',
      );
    }
    _cookie = cookie;
  }

  @override
  Future<DshCookie> login(String token) async {
    final uri = endpoint.withToken(token).loginUri;
    final response = await _http.send(
      DshHttpRequest(
        method: 'GET',
        uri: uri,
        authority: endpoint.authority,
        headers: const {
          'accept': 'text/html,application/xhtml+xml',
          'cache-control': 'no-store',
        },
        timeout: requestTimeout,
      ),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DshAuthException(
        'The launch token was rejected; open a fresh `dsh web` URL',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200 &&
        response.statusCode != 302 &&
        response.statusCode != 303) {
      throw httpStatusException(
        response.statusCode,
        '/?token=',
        body: response.body,
      );
    }
    final cookie = DshCookie.fromSetCookieHeaders(
      response.setCookie,
      authority: endpoint.authority,
    );
    if (cookie == null) {
      throw const DshProtocolException(
        'The login response carried no dsh-auth cookie',
      );
    }
    _cookie = cookie;
    return cookie;
  }

  @override
  Future<void> verify() async {
    final response = await get(endpoint.indexUri);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw DshAuthException(
        'The stored DSH session is no longer accepted',
        statusCode: response.statusCode,
      );
    }
    if (!response.isSuccess) {
      throw httpStatusException(response.statusCode, '/', body: response.body);
    }
  }

  @override
  Future<DshHttpResponse> post(String endpoint, Object? envelope) {
    return _http.send(
      DshHttpRequest(
        method: 'POST',
        uri: this.endpoint.apiUri(endpoint),
        authority: this.endpoint.authority,
        headers: _authenticatedHeaders(contentType: 'application/json'),
        body: utf8.encode(jsonEncode(envelope)),
        timeout: requestTimeout,
      ),
    );
  }

  @override
  Future<DshHttpResponse> get(Uri uri) {
    return _http.send(
      DshHttpRequest(
        method: 'GET',
        uri: uri,
        authority: endpoint.authority,
        headers: _authenticatedHeaders(),
        timeout: requestTimeout,
      ),
    );
  }

  @override
  Future<DshHttpResponse> postBytes(
    Uri uri,
    List<int> bytes, {
    required String contentType,
  }) {
    return _http.send(
      DshHttpRequest(
        method: 'POST',
        uri: uri,
        authority: endpoint.authority,
        headers: _authenticatedHeaders(contentType: contentType),
        body: bytes,
        timeout: const Duration(minutes: 10),
      ),
    );
  }

  @override
  Future<DshSocket> openMux() async {
    final cookie = _cookie;
    if (cookie == null) {
      throw const DshAuthException('Not logged in to this DeepSeek Harness');
    }
    return _http.upgrade(
      DshHttpRequest(
        method: 'GET',
        uri: endpoint.muxUri,
        authority: endpoint.authority,
        headers: {
          'cookie': cookie.header,
          'accept': '*/*',
          'cache-control': 'no-store',
        },
        timeout: connectTimeout,
      ),
    );
  }

  @override
  Future<void> close({bool force = false}) async {
    _http.close(force: force);
  }

  Map<String, String> _authenticatedHeaders({String? contentType}) {
    final cookie = _cookie;
    return {
      if (contentType != null) 'content-type': contentType,
      'accept': 'application/json',
      if (cookie != null) 'cookie': cookie.header,
      if (!endpoint.secure) 'cache-control': 'no-store',
    };
  }
}

/// The real `dart:io` byte-level client.
class DshIoHttpClient implements DshHttpClient {
  DshIoHttpClient({
    this.connectTimeout = const Duration(seconds: 10),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client
      ..connectionTimeout = connectTimeout
      ..autoUncompress = true
      ..idleTimeout = const Duration(seconds: 15);
  }

  final Duration connectTimeout;
  final HttpClient _client;
  bool _closed = false;

  @override
  Future<DshHttpResponse> send(DshHttpRequest request) async {
    try {
      final httpRequest = await _client
          .openUrl(request.method, request.uri)
          .timeout(request.timeout);
      httpRequest.followRedirects = request.followRedirects;
      _applyHeaders(httpRequest, request);
      final body = request.body;
      if (body != null) {
        httpRequest.headers.contentLength = body.length;
        httpRequest.add(body);
      }
      final response = await httpRequest.close().timeout(request.timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(request.timeout)) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      return DshHttpResponse(
        statusCode: response.statusCode,
        headers: {
          for (final name in _contentHeaderNames)
            if (response.headers.value(name) != null)
              name: response.headers.value(name)!,
        },
        setCookie: response.headers[HttpHeaders.setCookieHeader] ?? const [],
        body: utf8.decode(bytes, allowMalformed: true),
        bytes: bytes,
      );
    } on TimeoutException catch (error) {
      throw DshTransportException(
        'The Host did not answer ${request.uri.path} in time',
        cause: error,
      );
    } on SocketException catch (error) {
      throw DshTransportException(
        'Cannot reach ${request.authority}: ${error.message}',
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw DshTransportException(
        'TLS handshake with ${request.authority} failed',
        cause: error,
      );
    } on HttpException catch (error) {
      throw DshTransportException(
        'HTTP transport to ${request.authority} failed: ${error.message}',
        cause: error,
      );
    } on DshException {
      rethrow;
    } catch (error) {
      throw DshTransportException(
        'HTTP transport to ${request.authority} failed',
        cause: error,
      );
    }
  }

  @override
  Future<DshSocket> upgrade(DshHttpRequest request) async {
    try {
      final socket = await WebSocket.connect(
        request.uri.toString(),
        headers: {
          for (final entry in request.headers.entries)
            if (entry.key.toLowerCase() != 'host') entry.key: entry.value,
        },
        compression: CompressionOptions.compressionDefault,
        customClient: _client,
      ).timeout(request.timeout);
      socket.pingInterval = const Duration(seconds: 15);
      return _IoDshSocket(socket);
    } on TimeoutException catch (error) {
      throw DshTransportException(
        'The mux WebSocket did not open in time',
        cause: error,
      );
    } on WebSocketException catch (error) {
      final message = error.message.toLowerCase();
      if (message.contains('401') || message.contains('unauthorized')) {
        throw DshAuthException(
          'The Host rejected the mux WebSocket session',
          statusCode: 401,
        );
      }
      if (message.contains('403') || message.contains('forbidden')) {
        throw DshAuthException(
          'The Host refused the mux WebSocket address',
          statusCode: 403,
        );
      }
      if (message.contains('409') || message.contains('conflict')) {
        throw DshAuthException(
          'Another client already owns this DSH peer',
          statusCode: 409,
        );
      }
      throw DshTransportException(
        'The mux WebSocket could not be opened',
        cause: error,
      );
    } on SocketException catch (error) {
      throw DshTransportException(
        'Cannot reach the mux WebSocket: ${error.message}',
        cause: error,
      );
    } on HttpException catch (error) {
      throw DshTransportException(
        'The mux WebSocket upgrade failed: ${error.message}',
        cause: error,
      );
    } on DshException {
      rethrow;
    } catch (error) {
      throw DshTransportException(
        'The mux WebSocket upgrade failed',
        cause: error,
      );
    }
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _client.close(force: force);
  }

  static const List<String> _contentHeaderNames = [
    'content-type',
    'content-length',
    'cache-control',
    'location',
  ];

  void _applyHeaders(HttpClientRequest request, DshHttpRequest source) {
    request.headers.set(HttpHeaders.hostHeader, source.authority);
    for (final entry in source.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
  }
}

class _IoDshSocket implements DshSocket {
  _IoDshSocket(this._socket);

  final WebSocket _socket;
  final StreamController<Object?> _frames = StreamController<Object?>();
  bool _done = false;

  @override
  Stream<Object?> get frames {
    _start();
    return _frames.stream;
  }

  bool _started = false;

  void _start() {
    if (_started) return;
    _started = true;
    _socket.listen(
      (Object? data) {
        try {
          _frames.add(_decode(data));
        } on DshException catch (error, stack) {
          _frames.addError(error, stack);
          unawaited(close(1003, 'unsupported frame'));
        } catch (error) {
          _frames.addError(
            DshProtocolException('Unparseable mux frame: $error'),
          );
          unawaited(close(1003, 'unsupported frame'));
        }
      },
      onError: (Object error, StackTrace stack) {
        _frames.addError(
          DshTransportException('The mux WebSocket failed', cause: error),
          stack,
        );
        unawaited(_finish());
      },
      onDone: () => unawaited(_finish()),
      cancelOnError: false,
    );
  }

  static Object? _decode(Object? data) {
    if (data is String) return jsonDecode(data);
    if (data is List<int>) return jsonDecode(utf8.decode(data));
    throw const DshProtocolException('The mux sent a non-text frame');
  }

  Future<void> _finish() async {
    if (_done) return;
    _done = true;
    await _frames.close();
  }

  @override
  void send(Object? frame) {
    if (_done) return;
    _socket.add(jsonEncode(frame));
  }

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close([int code = 1000, String? reason]) async {
    if (_done) return;
    _done = true;
    await _socket.close(code, reason);
    await _frames.close();
  }
}
