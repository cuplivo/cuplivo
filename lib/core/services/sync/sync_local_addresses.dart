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

/// How many addresses this device advertises at most. The pairing QR has to
/// stay scannable at its fixed size and a human may be typing the list by hand,
/// so an unbounded adapter list is worse than a bounded, well-chosen one.
const kMaxLanCandidates = 4;

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

/// Whether two addresses are literals on the same IPv4 /24.
///
/// A /24 is the unit a home or office LAN hands out, so a candidate that shares
/// one with an address this device holds is on the network this device is
/// standing on, while one that does not is a memory of somewhere else. That is
/// the ordering hint a dial needs when a peer carries addresses from several
/// networks: the address this network reaches directly is tried first.
///
/// Anything that is not an IPv4 literal is never "same subnet", IPv6 included —
/// a v6 candidate arrives with its own round.
bool sameIpv4Subnet(String a, String b) {
  final left = _ipv4Prefix(a);
  if (left == null) return false;
  return left == _ipv4Prefix(b);
}

/// The `a.b.c` prefix of an IPv4 literal, or null when [address] is not one.
/// Only plain digits are an octet: a padded or signed form (`010.0.0.1`,
/// `+10.0.0.1`) is not the literal a peer sends, and treating it as equal would
/// match two different addresses.
String? _ipv4Prefix(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  for (final part in parts) {
    if (!_octetPattern.hasMatch(part)) return null;
    if (int.parse(part) > 255) return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

final RegExp _octetPattern = RegExp(r'^\d{1,3}$');

/// The canonical host form every layer stores and dials: surrounding brackets
/// stripped, and an IPv4-mapped IPv6 literal (`::ffff:a.b.c.d` — what a
/// dual-stack listener reports for an IPv4 caller) reduced to its IPv4 form.
///
/// A mapped form must not survive into storage: it is a valid address to a
/// socket but not to a URI (`Uri.parse` wants brackets) or to a human, and the
/// same endpoint would otherwise live under two names. Anything unparseable
/// passes through untouched — deciding what to *drop* is the job of the
/// usability predicates, not this one's.
String normalizeHost(String host) {
  var candidate = host.trim();
  if (candidate.startsWith('[') && candidate.endsWith(']')) {
    candidate = candidate.substring(1, candidate.length - 1);
  }
  final address = InternetAddress.tryParse(candidate);
  if (address != null && address.type == InternetAddressType.IPv6) {
    final raw = address.rawAddress;
    var mapped = true;
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) {
        mapped = false;
        break;
      }
    }
    if (mapped && raw[10] == 0xff && raw[11] == 0xff) {
      return '${raw[12]}.${raw[13]}.${raw[14]}.${raw[15]}';
    }
  }
  return candidate;
}

/// The host as a URI authority carries it: an IPv6 literal bracketed, an IPv4
/// address unchanged. A bare IPv6 literal inside `Uri.parse` is not a URI.
String uriHost(String host) {
  final address = InternetAddress.tryParse(host);
  return address != null && address.type == InternetAddressType.IPv6
      ? '[$host]'
      : host;
}

/// The endpoint as a human and the pairing QR read it: `host:port`, the IPv6
/// literal bracketed so the port is unambiguous to both a parser (the payload
/// splits on the last colon) and a person typing it.
String formatHostPort(String host, int port) => '${uriHost(host)}:$port';

/// Interface stems that are never a peer's route to this device: virtual
/// adapters (VMware, VirtualBox, Hyper-V, Docker/WSL), VPN and tunnel
/// interfaces, and a phone's cellular interfaces.
///
/// They are excluded rather than demoted because a *shared clone* subnet is
/// actively harmful on the pairing path: two machines that both run VirtualBox
/// carry the same default host-only network, so a joiner trying that candidate
/// reaches *itself*, fails the certificate pin, and aborts the attempt. A
/// demoted-but-present candidate would keep that failure reachable.
const _excludedStems = <String>[
  'vmware',
  'vmnet',
  'virtualbox',
  'vethernet',
  'hyper-v',
  'docker',
  'wsl',
  'wireguard',
  'tailscale',
  'zerotier',
  'nordlynx',
  'bluetooth',
  'teredo',
  'isatap',
  'dummy',
];

/// Stems matched by prefix, because the platform appends an index
/// (`rmnet_data0`, `utun3`) and an indexed name is what the OS reports.
const _excludedPrefixes = <String>[
  'tun',
  'tap',
  'utun',
  'wg',
  'ppp',
  'ipsec',
  'rmnet',
  'clat',
  'pdp_ip',
  'ccmni',
  'awdl',
  'llw',
];

/// Whether [name] belongs to an interface a peer should not be pointed at.
///
/// Deliberately **not** excluded, because they carry the address a tethered
/// peer must dial: `bridge*` (an iPhone's personal hotspot lives on
/// `bridge100`), Windows' "Local Area Connection* N" (the mobile hotspot
/// adapter), `swlan*` (Android soft AP) and every ordinary `en`/`eth`/`wlan`/
/// `Wi-Fi` name — including the localized ones a non-English Windows reports.
bool isVirtualInterfaceName(String name) {
  // Trailing digits come from the platform's adapter index, not the stem.
  final base = name.toLowerCase().replaceAll(RegExp(r'\d+$'), '').trim();
  if (base.isEmpty) return false;
  for (final stem in _excludedStems) {
    if (base.contains(stem)) return true;
  }
  for (final prefix in _excludedPrefixes) {
    if (base.startsWith(prefix)) return true;
  }
  return false;
}

/// The candidates this device advertises: the usable addresses that are not
/// carried by a virtual, tunnel or cellular interface, in interface order,
/// capped at [kMaxLanCandidates].
List<LanAddress> selectLanCandidates(List<LanAddress> addresses) {
  final kept = <LanAddress>[];
  for (final address in addresses) {
    if (isVirtualInterfaceName(address.name)) continue;
    kept.add(address);
    if (kept.length >= kMaxLanCandidates) break;
  }
  return kept;
}
