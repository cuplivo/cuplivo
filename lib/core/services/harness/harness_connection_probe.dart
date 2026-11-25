import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'harness_http_cookies.dart';

/// Why a DeepSeek Harness WebUI link could not be turned into a session.
enum HarnessConnectionFailure {
  /// Not an http(s) URL with a host.
  invalidUrl,

  /// The URL carries no `token` query parameter. A DSH WebUI has to be opened
  /// through the link `dsh web` prints; the bare address answers 401.
  missingToken,

  /// The host could not be reached (DNS, TCP, TLS, timeout).
  unreachable,

  /// The host answered, but refused the token.
  rejected,

  /// The token was accepted, but the JSON-RPC API did not answer with the
  /// session list — a different server, a proxy in front, or a broken instance.
  apiUnavailable,

  /// The pasted tailcat text is not an address (or a pairing command).
  invalidTailcatAddress,

  /// The tailcat tunnel could not be established: the peer is offline, the
  /// relay is unreachable, or the address has been rotated.
  tailcatUnavailable,

  /// The current build has no tailcat client (the web target).
  tailcatUnsupported,
}

/// The outcome of [HarnessConnectionProbe.check].
class HarnessConnectionResult {
  const HarnessConnectionResult.connected() : failure = null;

  const HarnessConnectionResult.failed(HarnessConnectionFailure this.failure);

  final HarnessConnectionFailure? failure;

  bool get isConnected => failure == null;
}

/// Proves a DeepSeek Harness WebUI link works, by doing what the embedded
/// WebUI will do: redeem the launch token for the operator cookie and answer
/// one authenticated JSON-RPC request.
///
/// The launch link is not a page that can simply be fetched: DSH signs the
/// token into a browser cookie (303), the WebUI then exchanges it for an
/// operator cookie at `/connect` (302), and every call after that carries the
/// operator cookie. Checking all three steps means "已连接" describes a usable
/// instance, not just a reachable host; a rotated token or a fronting proxy
/// fails here instead of in the embedded view.
class HarnessConnectionProbe {
  const HarnessConnectionProbe({this.timeout = const Duration(seconds: 20)});

  /// Bounds the whole exchange, not one request: a host that accepts TCP and
  /// then stalls must not leave the settings page spinning.
  final Duration timeout;

  Future<HarnessConnectionResult> check(String rawUrl) async {
    final launchUri = _parseLaunchUri(rawUrl);
    if (launchUri == null) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.invalidUrl,
      );
    }
    final token = launchUri.queryParameters['token']?.trim();
    if (token == null || token.isEmpty) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.missingToken,
      );
    }
    final base = _baseUri(launchUri);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      return await _exchange(client, base, token).timeout(timeout);
    } on TimeoutException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.unreachable,
      );
    } on SocketException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.unreachable,
      );
    } on HandshakeException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.unreachable,
      );
    } on HttpException {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.unreachable,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<HarnessConnectionResult> _exchange(
    HttpClient client,
    Uri base,
    String token,
  ) async {
    // 1. The link printed by `dsh web`: 303 See Other plus the browser cookie.
    final launchResponse = await _get(client, _withToken(base, token));
    final launchStatus = launchResponse.statusCode;
    final launchCookies = harnessResponseCookies(launchResponse);
    await launchResponse.drain<void>();
    if (_rejected(launchStatus)) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.rejected,
      );
    }
    if (launchStatus >= HttpStatus.badRequest) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.apiUnavailable,
      );
    }

    // 2. The operator cookie the WebUI's JSON-RPC calls use.
    final connectUri = base.replace(
      path: _joinPath(base.path, 'connect'),
      queryParameters: <String, String>{
        'token': token,
        'interactions': 'answer',
      },
    );
    final connectResponse = await _get(client, connectUri);
    final connectStatus = connectResponse.statusCode;
    final cookies = <String, String>{
      ...launchCookies,
      ...harnessResponseCookies(connectResponse),
    };
    await connectResponse.drain<void>();
    if (_rejected(connectStatus)) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.rejected,
      );
    }
    if (connectStatus >= HttpStatus.badRequest) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.apiUnavailable,
      );
    }

    // 3. One authenticated JSON-RPC call — the same envelope the WebUI sends.
    final rpcId = const Uuid().v4();
    final listUri = base.replace(
      path: _joinPath(base.path, 'api/session/list'),
    );
    final request = await client.postUrl(listUri);
    request.followRedirects = false;
    final cookieHeader = harnessCookieHeader(cookies);
    if (cookieHeader != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.write(
      jsonEncode(<String, Object?>{
        'type': 'client-request',
        'rpcId': rpcId,
        'method': 'session/list',
        // DSH's remote gateway reads args from exactly one `args` field, and
        // `session/list` declares its request object there.
        'payload': <String, Object?>{
          'args': <String, Object?>{'_request': <String, Object?>{}},
        },
      }),
    );
    final response = await request.close();
    final status = response.statusCode;
    final body = await response.transform(utf8.decoder).join();
    if (_rejected(status)) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.rejected,
      );
    }
    if (status != HttpStatus.ok) {
      return const HarnessConnectionResult.failed(
        HarnessConnectionFailure.apiUnavailable,
      );
    }
    return _readSessionListResponse(body, rpcId);
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/json');
    return request.close();
  }

  /// True only for the envelope this probe sent, with `ok: true` inside it. A
  /// 200 alone is not enough: DSH answers bad requests with 200 and `ok: false`.
  static HarnessConnectionResult _readSessionListResponse(
    String body,
    String rpcId,
  ) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const HarnessConnectionResult.failed(
          HarnessConnectionFailure.apiUnavailable,
        );
      }
      if (decoded['rpcId'] != rpcId) {
        return const HarnessConnectionResult.failed(
          HarnessConnectionFailure.apiUnavailable,
        );
      }
      final result = decoded['result'];
      if (result is Map && result['ok'] == true) {
        return const HarnessConnectionResult.connected();
      }
    } catch (_) {
      // Fall through: not a DSH response.
    }
    return const HarnessConnectionResult.failed(
      HarnessConnectionFailure.apiUnavailable,
    );
  }

  static bool _rejected(int status) =>
      status == HttpStatus.unauthorized || status == HttpStatus.forbidden;

  static Uri? _parseLaunchUri(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return uri;
  }

  static Uri _baseUri(Uri launchUri) => Uri(
    scheme: launchUri.scheme,
    userInfo: launchUri.userInfo,
    host: launchUri.host,
    port: launchUri.hasPort ? launchUri.port : null,
    path: launchUri.path,
  );

  static Uri _withToken(Uri base, String token) =>
      base.replace(queryParameters: <String, String>{'token': token});

  static String _joinPath(String basePath, String tail) {
    if (basePath.isEmpty || basePath == '/') return '/$tail';
    return basePath.endsWith('/') ? '$basePath$tail' : '$basePath/$tail';
  }
}
