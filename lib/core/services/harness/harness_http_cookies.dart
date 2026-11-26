import 'dart:io';

/// The cookies one HTTP response set, as name → value.
///
/// Both DeepSeek Harness probes redeem their own cookies out of a redirect
/// response and replay them by hand rather than relying on a cookie jar: the
/// probes use a plain [HttpClient], which has none, and the exact set of
/// cookies is part of what the probes check.
Map<String, String> harnessResponseCookies(HttpClientResponse response) {
  final cookies = <String, String>{};
  final values = response.headers[HttpHeaders.setCookieHeader];
  if (values == null) return cookies;
  for (final raw in values) {
    // One cookie per header line: "name=value; Path=/; HttpOnly; ...".
    final pair = raw.split(';').first.trim();
    final equals = pair.indexOf('=');
    if (equals <= 0) continue;
    cookies[pair.substring(0, equals).trim()] = pair
        .substring(equals + 1)
        .trim();
  }
  return cookies;
}

/// Renders [cookies] as one `Cookie` request header, or `null` when empty.
String? harnessCookieHeader(Map<String, String> cookies) {
  if (cookies.isEmpty) return null;
  return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}
