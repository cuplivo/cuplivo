import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

/// SSRF guard for the built-in web fetch engine.
///
/// `web_fetch` connects directly (no provider in the middle), so a
/// prompt-injected URL could otherwise steer the model into fetching internal
/// hosts — loopback, RFC 1918 private ranges, link-local, cloud-metadata
/// (169.254.169.254) — and in download mode write those bytes into
/// `@workspaces`. Every direct connection is validated before a socket is
/// opened, and each redirect hop is re-validated.
///
/// DNS-layer limits (see also [resolvedBlockReason]): under a fake-IP proxy,
/// answers cannot distinguish virtual from real hosts; IPv6 fake-IP ranges
/// (user-configured `fake-ip-range6`, ULA space) are deliberately not
/// exempted since fc00::/7 is also a genuine internal range.
class WebFetchTargetGuard {
  WebFetchTargetGuard._();

  /// Maximum redirect hops followed while re-validating each target.
  static const int maxRedirectHops = 5;

  /// When false, private/loopback/metadata targets are allowed so tests can
  /// exercise a local HTTP server. Production stays true.
  @visibleForTesting
  static bool blockPrivateTargets = true;

  /// Returns a rejection reason when [url] targets a blocked literal IP or
  /// `localhost`, otherwise null. Synchronous — used at parse time and before
  /// every connect.
  static String? literalBlockReason(Uri url) {
    if (!blockPrivateTargets) return null;
    if (url.host.toLowerCase() == 'localhost') {
      return 'localhost is not an allowed web_fetch target';
    }
    final address = InternetAddress.tryParse(url.host);
    if (address != null && _isBlockedAddress(address)) {
      return '${url.host} is a loopback/private/link-local/metadata address '
          'and is not an allowed web_fetch target';
    }
    return null;
  }

  /// Resolver hook so tests can inject synthetic DNS answer sets without
  /// depending on the real network. Defaults to the platform resolver.
  @visibleForTesting
  static Future<List<InternetAddress>> Function(String host) redirectResolve =
      (String host) => InternetAddress.lookup(host);

  /// Returns a rejection reason when [url]'s hostname resolves to a blocked
  /// address, otherwise null. Best-effort: DNS failures are not treated as
  /// blocked (the connection itself will surface the real error). Only
  /// hostnames are resolved — literal IPs are covered by [literalBlockReason].
  static Future<String?> resolvedBlockReason(Uri url) async {
    if (!blockPrivateTargets) return null;
    if (url.host.isEmpty || InternetAddress.tryParse(url.host) != null) {
      return null;
    }
    final List<InternetAddress> addresses;
    try {
      addresses = await redirectResolve(url.host);
    } catch (e) {
      debugPrint('[web_fetch] DNS lookup failed for ${url.host}: $e');
      return null;
    }
    for (final address in addresses) {
      // DNS answers that fall inside the fake-IP range (198.18.0.0/15,
      // IANA benchmark space) are NOT real targets. They are virtual
      // addresses injected by a fake-IP proxy (Clash / mihomo / sing-box
      // default to this range): the OS resolves the public hostname into a
      // synthetic loopback-like address that the proxy then rewrites in
      // software. Treating these as blocked would reject every ordinary
      // public site under such a proxy. Tradeoff: under a fake-IP proxy,
      // internal-only hostnames (e.g. intranet.corp.com) also resolve to
      // fake addresses and are routed to the real internal host by the
      // proxy, so hostname-level SSRF protection is inherently limited —
      // only literal-IP URLs and `localhost` stay hard-blocked.
      if (_isBlockedAddress(address, allowFakeIpRange: true)) {
        return '${url.host} resolves to $address, a loopback/private/'
            'link-local/metadata address and not an allowed web_fetch target';
      }
    }
    return null;
  }

  static bool _isBlockedAddress(
    InternetAddress address, {
    bool allowFakeIpRange = false,
  }) {
    if (address.isLoopback || address.isLinkLocal) return true;
    if (address.rawAddress.isEmpty) return true;
    if (address.type == InternetAddressType.IPv6) {
      // ULA fc00::/7.
      if (address.rawAddress[0] & 0xfe == 0xfc) return true;
      // Unspecified ::.
      if (address.rawAddress.every((b) => b == 0)) return true;
      // IPv4-mapped ::ffff:a.b.c.d.
      final raw = address.rawAddress;
      if (raw.length == 16 &&
          raw[0] == 0 &&
          raw[1] == 0 &&
          raw[2] == 0 &&
          raw[3] == 0 &&
          raw[4] == 0 &&
          raw[5] == 0 &&
          raw[6] == 0 &&
          raw[7] == 0 &&
          raw[8] == 0 &&
          raw[9] == 0 &&
          raw[10] == 0xff &&
          raw[11] == 0xff) {
        return _isBlockedAddress(
          InternetAddress.fromRawAddress(raw.sublist(12)),
          allowFakeIpRange: allowFakeIpRange,
        );
      }
      return false;
    }
    final bytes = address.rawAddress;
    if (bytes.length != 4) return false;
    final a = bytes[0];
    final b = bytes[1];
    if (a == 0) return true; // 0.0.0.0/8 "this network"
    if (a == 127) return true; // loopback
    if (a == 10) return true; // 10/8
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64/10
    if (a == 169 && b == 254) return true; // link-local / metadata
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16/12
    if (a == 192 && b == 168) return true; // 192.168/16
    // 198.18.0.0/15 is the IANA benchmark block. Its only real-world use is
    // the fake-IP range of Clash / mihomo / sing-box proxies, so answers in
    // DNS lookups are virtual injected addresses, not real internal hosts.
    // Only let those through when the address came from a resolved lookup;
    // an explicit literal IP in that range is still rejected below.
    if (a == 198 && (b == 18 || b == 19) && !allowFakeIpRange) return true;
    if (a >= 224) return true; // multicast + reserved
    return false;
  }
}

/// Combined literal + DNS check for a target before connecting.
/// Returns a rejection reason, or null when allowed.
Future<String?> webFetchTargetBlockReason(Uri url) async {
  final literal = WebFetchTargetGuard.literalBlockReason(url);
  if (literal != null) return literal;
  return WebFetchTargetGuard.resolvedBlockReason(url);
}
