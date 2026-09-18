import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Prefix of the LAN sync connection payload carried by the server QR code
/// and the "copy link" action. Mirrors the repo's provider-share convention
/// (`ai-provider:v1:`): a short marker followed by JSON.
const lanSyncLinkPrefix = 'cuplivo-lansync:v1:';

/// Parsed contents of a LAN sync QR/link payload.
///
/// [hosts] are all of the server's LAN addresses in display order; the
/// initiator tries them in order and stops at the first one that responds.
typedef LanSyncLink = ({List<String> hosts, int port, String pin});

/// Builds the QR/link payload for the server's [hosts], [port] and session
/// [pin].
String buildLanSyncLink({
  required List<String> hosts,
  required int port,
  required String pin,
}) {
  return '$lanSyncLinkPrefix${jsonEncode({'hosts': hosts, 'port': port, 'pin': pin})}';
}

/// Parses a scanned/pasted LAN sync payload. Returns null when [raw] is not a
/// valid sync link (foreign QR code, truncated JSON, missing/invalid fields).
LanSyncLink? parseLanSyncLink(String raw) {
  final text = raw.trim();
  if (!text.startsWith(lanSyncLinkPrefix)) return null;
  try {
    final decoded = jsonDecode(text.substring(lanSyncLinkPrefix.length));
    if (decoded is! Map) return null;
    final hosts = decoded['hosts'];
    final port = decoded['port'];
    final pin = decoded['pin'];
    if (hosts is! List || port is! int || pin is! String) return null;
    final seen = <String>{};
    final parsedHosts = [
      for (final host in hosts)
        if (host is String && host.isNotEmpty && seen.add(host)) host,
    ];
    if (parsedHosts.isEmpty || port < 1 || port > 65535 || pin.isEmpty) {
      return null;
    }
    return (hosts: parsedHosts, port: port, pin: pin);
  } catch (e) {
    // Junk payload (foreign/truncated QR): recoverable, the caller shows a
    // localized "invalid link" message.
    debugPrint('lan sync: invalid link payload: $e');
    return null;
  }
}
