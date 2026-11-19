/// Parses what the user pastes into the "connect to a DeepSeek Harness" form
/// and derives every URI the client needs.
///
/// Accepted inputs (0.2.2 `dsh web`):
///
/// ```text
/// dsh web: http://127.0.0.1:3080/?token=<launch-token>
/// http://127.0.0.1:3080/?token=<launch-token>
/// 127.0.0.1:3080/?token=<launch-token>
/// http://192.168.1.20:3080            (resume with a stored cookie)
/// https://example.test/ui/?token=…    (Host mounted under a path prefix)
/// ```
///
/// The launch token is optional: a stored connection resumes with the cookie and
/// no token. The token (when present) is dropped from [baseUri]; the cookie the
/// Host mints is bound to [authority] (`host[:port]` as dialed), so every
/// request must send exactly that `Host` header.
library;

import 'dsh_errors.dart';

/// One DeepSeek Harness origin plus the parsed launch token.
final class DshEndpoint {
  const DshEndpoint({
    required this.baseUri,
    required this.authority,
    required this.secure,
    this.token,
  });

  /// Parses a pasted WebUI URL, with or without the `dsh web:` prefix.
  ///
  /// Throws [DshEndpointException] with `field: 'url'` for an unusable address
  /// and `field: 'token'` for a present-but-empty token, so a form can attach
  /// the message to the right input.
  factory DshEndpoint.parse(String input) {
    final text = _stripDecorations(input);
    if (text.isEmpty) {
      throw const DshEndpointException('Enter the WebUI URL', field: 'url');
    }

    // The first scheme in the text must be http(s); catch ws/ftp/etc. early so
    // the error says "scheme" instead of "not a URL".
    final scheme = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(text);
    if (scheme != null) {
      final name = scheme.group(1)!.toLowerCase();
      if (name != 'http' && name != 'https') {
        throw DshEndpointException(
          'Unsupported URL scheme "$name"',
          field: 'url',
        );
      }
    }

    // A whole launch line ("dsh web: http://…") or any text containing a URL:
    // take the first http(s) URL it carries.
    final urlMatch = RegExp(r'''https?://[^\s<>"']+''').firstMatch(text);
    String candidate;
    if (urlMatch != null) {
      candidate = _trimTrailingPunctuation(urlMatch.group(0)!);
    } else {
      // No scheme: `host:port[/path][?query]`. A bare host is accepted too and
      // defaults to http.
      final normalized = _stripDshWebPrefix(text);
      if (normalized.isEmpty) {
        throw const DshEndpointException('Enter the WebUI URL', field: 'url');
      }
      candidate = 'http://$normalized';
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) {
      throw const DshEndpointException(
        'That does not look like a URL',
        field: 'url',
      );
    }
    // `Uri.parse` happily percent-encodes spaces inside the authority
    // (`not a url at all` -> host `not%20a%20url%20at%20all`); reject anything
    // that is not a plain DNS name / IPv4 / IPv6 literal instead of dialing it.
    final host = uri.host;
    final looksLikeIpv6 = host.contains(':');
    final validHost = looksLikeIpv6
        ? RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(host)
        : RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host);
    if (!validHost) {
      throw const DshEndpointException(
        'That does not look like a URL',
        field: 'url',
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw DshEndpointException(
        'Unsupported URL scheme "${uri.scheme}"',
        field: 'url',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const DshEndpointException(
        'Remove the credentials from the URL; DSH uses the launch token',
        field: 'url',
      );
    }
    if (uri.port == 0) {
      throw const DshEndpointException('Invalid port in the URL', field: 'url');
    }

    final rawToken = uri.queryParameters['token'];
    String? token;
    if (rawToken != null) {
      token = rawToken.trim();
      if (token.isEmpty) {
        throw const DshEndpointException(
          'The token in the URL is empty',
          field: 'token',
        );
      }
      if (token.contains(RegExp(r'\s'))) {
        throw const DshEndpointException(
          'The token in the URL is malformed',
          field: 'token',
        );
      }
    }

    var mount = uri.path;
    while (mount.endsWith('/')) {
      mount = mount.substring(0, mount.length - 1);
    }
    if (mount == '/') {
      mount = '';
    }

    final secure = uri.scheme == 'https';
    final authority = _authorityOf(uri, secure: secure);
    final base = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: mount.isEmpty ? null : mount,
    );

    return DshEndpoint(
      baseUri: base,
      authority: authority,
      secure: secure,
      token: token,
    );
  }

  /// Scheme + authority + optional mount path, no token and no query.
  final Uri baseUri;

  /// `host[:port]` exactly as the Host header carries it and the cookie is
  /// bound to. IPv6 literals keep their brackets; a default port is omitted.
  final String authority;

  /// Whether the connection uses https/wss.
  final bool secure;

  /// Launch token parsed from `?token=`; null when resuming with a cookie.
  final String? token;

  /// The path prefix the Host is mounted under (`''` for a root deployment).
  String get mountPath => baseUri.path;

  bool get hasToken => token != null && token!.isNotEmpty;

  /// `scheme://authority`, used for diagnostics and the WebView's origin.
  String get origin => '${baseUri.scheme}://$authority';

  /// `GET <base>/` — the SPA index, also the cookie proof route.
  Uri get indexUri => _resolvePath('/');

  /// `GET <base>/?token=<launch token>` — the one-shot login.
  ///
  /// Throws [DshEndpointException] when the endpoint has no token (resume with
  /// a stored cookie instead).
  Uri get loginUri {
    if (!hasToken) {
      throw const DshEndpointException(
        'No launch token in this URL',
        field: 'token',
      );
    }
    return indexUri.replace(queryParameters: {'token': token});
  }

  /// `POST <base>/api/<endpoint>`.
  Uri apiUri(String endpoint) {
    final clean = endpoint.trim();
    if (clean.isEmpty || clean.startsWith('/') || clean.contains(' ')) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'not a Remote endpoint name',
      );
    }
    return _resolvePath('/api/$clean');
  }

  /// `ws(s)://<authority><mount>/api/remote.mux`.
  Uri get muxUri {
    return _resolvePath(
      '/api/remote.mux',
    ).replace(scheme: secure ? 'wss' : 'ws');
  }

  /// `POST <base>/api/session/uploadFileBinary?sessionId=…`.
  Uri uploadUri(String sessionId, {String? name, String? mediaType}) {
    final query = <String, String>{'sessionId': sessionId};
    if (name != null && name.isNotEmpty) query['name'] = name;
    if (mediaType != null && mediaType.isNotEmpty) {
      query['mediaType'] = mediaType;
    }
    return apiUri('session/uploadFileBinary').replace(queryParameters: query);
  }

  /// `GET <base>/api/file?path=…` — authenticated Host file bytes.
  Uri fileUri(String absolutePath, {String? version}) {
    final query = <String, String>{'path': absolutePath};
    if (version != null && version.isNotEmpty) query['v'] = version;
    return apiUri('file').replace(queryParameters: query);
  }

  DshEndpoint withToken(String value) {
    if (value.trim().isEmpty) {
      throw const DshEndpointException(
        'The launch token is empty',
        field: 'token',
      );
    }
    return DshEndpoint(
      baseUri: baseUri,
      authority: authority,
      secure: secure,
      token: value.trim(),
    );
  }

  DshEndpoint withoutToken() =>
      DshEndpoint(baseUri: baseUri, authority: authority, secure: secure);

  Uri _resolvePath(String path) {
    final joined = '$mountPath$path';
    return baseUri.replace(path: joined.startsWith('/') ? joined : '/$joined');
  }

  static String _trimTrailingPunctuation(String value) {
    var text = value;
    const trailing = '.,;:)]}>`';
    while (text.isNotEmpty && trailing.contains(text[text.length - 1])) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  static String _authorityOf(Uri uri, {required bool secure}) {
    final defaultPort = secure ? 443 : 80;
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final showPort = uri.hasPort && uri.port != defaultPort;
    return showPort ? '$host:${uri.port}' : host;
  }

  static String _stripDecorations(String input) {
    var text = input.trim();
    // Owners paste the whole line, sometimes with a trailing period or in
    // backticks/quotes from a chat message.
    if (text.length >= 2) {
      final first = text[0];
      final last = text[text.length - 1];
      const pairs = {'"': '"', "'": "'", '`': '`', '<': '>', '“': '”'};
      if (pairs[first] == last) {
        text = text.substring(1, text.length - 1).trim();
      }
    }
    if (text.startsWith('//')) text = text.substring(2);
    return text;
  }

  static String _stripDshWebPrefix(String input) {
    return input
        .replaceFirst(RegExp(r'^dsh\s+web\s*:\s*', caseSensitive: false), '')
        .trim();
  }

  @override
  bool operator ==(Object other) =>
      other is DshEndpoint &&
      other.baseUri == baseUri &&
      other.authority == authority &&
      other.token == token;

  @override
  int get hashCode => Object.hash(baseUri, authority, token);

  /// Deliberately omits the token so the endpoint is safe to log.
  @override
  String toString() =>
      'DshEndpoint($origin${mountPath.isEmpty ? '' : mountPath})';
}
