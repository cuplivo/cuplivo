import 'dart:io';

/// LAN address helpers for the pairing screen: the device showing a PIN also
/// shows the `ip:port` endpoints the other device can type, and the pairing QR
/// carries the same candidates.
///
/// The rule is "every unicast IPv4 the OS reports". Loopback, link-local and
/// IPv6 never reach here — the enumeration excludes them (`includeLoopback:
/// false`, `includeLinkLocal: false`, `type: IPv4`) and the filter drops them
/// again defensively. A *public* address is deliberately **not** excluded: a
/// campus network hands out globally routable IPv4 addresses directly, with no
/// NAT in between, and a peer on the same segment reaches them. Restricting the
/// list to RFC1918 made exactly those devices advertise nothing at all.
///
/// The interface name travels with each address so candidate selection can tell
/// a real NIC from a virtual adapter without guessing from the address range —
/// virtual adapters live in RFC1918 space, which is the opposite of what the
/// address range alone would suggest.

/// One address of this device, tagged with the interface carrying it.
typedef LanAddress = ({String name, String address});

/// Whether [address] is a unicast IPv4 a peer could dial: not loopback, not
/// link-local, not multicast and not the reserved/broadcast blocks.
bool _isUsableUnicast(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.length != 4) return false;
  final first = raw[0];
  final second = raw[1];
  if (first == 0) return false; // "this network"
  if (first == 127) return false; // loopback
  if (first == 169 && second == 254) return false; // link-local
  if (first >= 224) return false; // multicast, reserved, broadcast
  return true;
}

/// Keeps unique usable unicast IPv4 addresses, preserving input order.
List<LanAddress> filterLanAddresses(List<LanAddress> addresses) {
  final kept = <LanAddress>[];
  final seen = <String>{};
  for (final candidate in addresses) {
    final address = InternetAddress.tryParse(candidate.address);
    if (address == null) continue;
    if (address.type != InternetAddressType.IPv4) continue;
    if (!_isUsableUnicast(address)) continue;
    if (!seen.add(candidate.address)) continue;
    kept.add(candidate);
  }
  return kept;
}

/// All unique unicast IPv4 addresses of this device, in interface order.
Future<List<LanAddress>> listLanAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return filterLanAddresses([
      for (final interface in interfaces)
        for (final address in interface.addresses)
          (name: interface.name, address: address.address),
    ]);
  } catch (_) {
    return const [];
  }
}
