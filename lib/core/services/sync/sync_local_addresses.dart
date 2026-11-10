import 'dart:io';

/// LAN address helpers for the pairing screen: the device showing a PIN also
/// shows the `ip:port` endpoints the other device can type, and the pairing QR
/// carries the same candidates.
///
/// The rule is "every unicast address the OS reports, in either family".
/// Loopback and link-local never reach here (`includeLoopback: false`,
/// `includeLinkLocal: false`) and the usability predicates drop them again
/// defensively, along with multicast, the reserved blocks and the IPv4-mapped
/// forms. The enumeration deliberately asks for no `type`: a dual-stack device
/// advertises its IPv6 addresses beside its IPv4 ones. A *public* address is
/// deliberately **not** excluded either — a campus network hands out globally
/// routable addresses directly, with no NAT in between, and a peer on the same
/// segment reaches them. Restricting the list to RFC1918 made exactly those
/// devices advertise nothing at all.
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

/// Whether [address] is a unicast IPv6 a peer could dial.
///
/// Kept: global unicast (`2000::/3`) and unique local (`fd00::/8`) — the two
/// ranges an interface actually holds and a peer on the same network can reach.
///
/// Dropped: link-local (`fe80::/10`), whose zone id is a property of *this*
/// device's interface and means nothing to a peer; multicast; the unspecified
/// address; the reserved `fc00::/8` half of the unique-local block; and the
/// IPv4-mapped (`::ffff:0:0/96`) and IPv4-compatible (`::/96`) forms, which are
/// an IPv4 address wearing an IPv6 shape and are enumerated as IPv4 instead.
bool _isUsableIpv6(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.length != 16) return false;
  // The keeps below are the whole decision: a mapped or compatible form starts
  // with a zero byte, which is neither `fd` nor inside `2000::/3`, so it falls
  // out here rather than being named as a rule of its own.
  final first = raw[0];
  if (first == 0xfd) return true; // unique local (fd00::/8)
  if (first >= 0x20 && first <= 0x3f) return true; // global unicast (2000::/3)
  return false;
}

/// Whether [address] is a unicast address of either family a peer could dial.
bool _isUsableAddress(InternetAddress address) {
  if (address.type == InternetAddressType.IPv4) {
    return _isUsableUnicast(address);
  }
  if (address.type == InternetAddressType.IPv6) return _isUsableIpv6(address);
  return false;
}

/// Keeps unique usable unicast addresses of either family, preserving input
/// order.
List<LanAddress> filterLanAddresses(List<LanAddress> addresses) {
  final kept = <LanAddress>[];
  final seen = <String>{};
  for (final candidate in addresses) {
    final normalized = normalizeHost(candidate.address);
    final address = InternetAddress.tryParse(normalized);
    if (address == null) continue;
    if (!_isUsableAddress(address)) continue;
    // Deduplicated and stored in the canonical form, so one interface reporting
    // an IPv4 address twice (plain and mapped) yields one candidate.
    if (!seen.add(normalized)) continue;
    kept.add((name: candidate.name, address: normalized));
  }
  return kept;
}

/// All unique usable unicast addresses of this device, in interface order —
/// IPv4 and IPv6 in one list, because a peer dials whichever it can reach.
Future<List<LanAddress>> listLanAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
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
/// Only a canonical octet counts: a padded or signed form (`010.0.0.1`,
/// `+10.0.0.1`) is not the literal a peer sends, and reading `010` as `10` would
/// match two different addresses.
String? _ipv4Prefix(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  for (final part in parts) {
    if (!_octetPattern.hasMatch(part)) return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

/// `0`–`255`, and no leading zero: `010` is a padded form, not the octet `10`.
final RegExp _octetPattern = RegExp(
  r'^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$',
);

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
