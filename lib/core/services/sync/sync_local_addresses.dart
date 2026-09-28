import 'dart:io';

/// LAN address helpers for the pairing screen: the device showing a PIN also
/// shows the `ip:port` endpoints the other device can type.
///
/// The filter is deliberately narrow — RFC1918 private ranges only — because
/// the list exists to be typed by a human; a loopback, link-local or virtual
/// adapter address would only produce a confusing dead end.

bool _isPrivate(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.length != 4) return false;
  final first = raw[0];
  final second = raw[1];
  if (first == 10) return true;
  if (first == 172 && second >= 16 && second <= 31) return true;
  if (first == 192 && second == 168) return true;
  return false;
}

/// Keeps only unique IPv4 addresses in private ranges (10/8, 172.16/12,
/// 192.168/16), preserving input order.
List<String> filterLanIpv4s(List<String> addresses) {
  final kept = <String>[];
  for (final text in addresses) {
    final address = InternetAddress.tryParse(text);
    if (address == null) continue;
    if (address.type != InternetAddressType.IPv4) continue;
    if (!_isPrivate(address)) continue;
    if (kept.contains(text)) continue;
    kept.add(text);
  }
  return kept;
}

/// All unique private IPv4 addresses of this device, in interface order.
Future<List<String>> listLocalIpv4s() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return filterLanIpv4s([
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ]);
  } catch (_) {
    return const [];
  }
}
