import 'package:flutter/foundation.dart';

/// The parsed form of the WebUI link a user pastes from `dsh web`.
///
/// `dsh web` prints something like
/// `dsh web: http://127.0.0.1:3080/?token=…`; a user may paste the whole line
/// or just `127.0.0.1:3080/?token=…`. Parsing separates the two things the app
/// needs differently:
///
/// - [baseUrl]/[authority]/[secure] are persisted with the connection record;
/// - [launchToken] exists only long enough to be handed to the login request.
///   It is never stored, and [toString] never includes it, so a stray log line
///   or error message cannot leak it.
///
/// The parser is intentionally strict about the shape: only an origin
/// (optionally with a trailing `/`) is accepted, so a link with a path prefix
/// fails loudly instead of producing a base URL the protocol client cannot
/// use. The protocol client will eventually own endpoint parsing; this model is
/// the small foundation-side version the creation form validates against.
@immutable
class DshWebUiLink {
  const DshWebUiLink._({
    required this.baseUrl,
    required this.authority,
    required this.secure,
    this.launchToken,
  });

  /// Origin without query/fragment, e.g. `http://127.0.0.1:3080`.
  final String baseUrl;

  /// `host[:port]` (IPv6 hosts stay bracketed), the authority a session cookie
  /// is bound to.
  final String authority;

  /// True when the origin is `https`.
  final bool secure;

  /// The one-shot launch token, or null when the pasted link carried none.
  final String? launchToken;

  bool get hasLaunchToken => launchToken != null;

  /// Parses a pasted link, returning null when it is not a usable http(s)
  /// origin.
  ///
  /// Accepted: `http(s)://host[:port]/?token=…`, `host:port/?token=…`,
  /// `host:port`, and the same with a `dsh web:` prefix before the URL. A
  /// non-empty path other than `/` is rejected (reverse-proxy prefix handling
  /// belongs to the protocol client).
  static DshWebUiLink? tryParse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    // The user may paste the whole `dsh web: <url>` line, so cut to the first
    // http(s) token instead of requiring a bare URL.
    final httpIndex = text.indexOf('http://');
    final httpsIndex = text.indexOf('https://');
    final start = switch ((httpIndex, httpsIndex)) {
      (-1, -1) => -1,
      (-1, _) => httpsIndex,
      (_, -1) => httpIndex,
      _ => httpIndex < httpsIndex ? httpIndex : httpsIndex,
    };
    if (start > 0) text = text.substring(start);
    if (start == -1 && text.contains('://')) return null;
    if (start == -1) text = 'http://$text';

    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
    // Only the origin is a valid server address. `/` is the same origin as an
    // empty path; anything else would silently drop a proxy prefix.
    if (uri.path.isNotEmpty && uri.path != '/') return null;

    final authority = _authorityOf(uri);
    final token = uri.queryParameters['token']?.trim();
    return DshWebUiLink._(
      baseUrl: '${uri.scheme}://$authority',
      authority: authority,
      secure: uri.scheme == 'https',
      launchToken: (token == null || token.isEmpty) ? null : token,
    );
  }

  static String _authorityOf(Uri uri) {
    final host = uri.host;
    final hostPart = host.contains(':') ? '[$host]' : host;
    return uri.hasPort ? '$hostPart:${uri.port}' : hostPart;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshWebUiLink &&
          other.baseUrl == baseUrl &&
          other.authority == authority &&
          other.secure == secure &&
          other.launchToken == launchToken;

  @override
  int get hashCode => Object.hash(baseUrl, authority, secure, launchToken);

  /// Never includes [launchToken]: a token belongs to one connect attempt and
  /// must not leak through logs or error messages.
  @override
  String toString() => 'DshWebUiLink($baseUrl, token: ${hasLaunchToken})';
}
