import 'dart:async';
import 'dart:io';

import 'sync_local_addresses.dart';

/// Budget for one pairing candidate's bare-TCP probe. Pairing is the one walk
/// that cannot authenticate first (no secret exists yet, and the QR path pins a
/// certificate it has already seen), so it keeps the cheap reachability probe:
/// a live LAN host answers a SYN in milliseconds.
const Duration kSyncPairingProbeTimeout = Duration(seconds: 2);

/// One probe attempt, injectable so tests can manufacture winners and losers
/// without real sockets. The default connects and immediately discards the
/// socket: this probe tests the *address*, never the peer — pairing identity is
/// decided by the PIN and the certificate that answers the request.
typedef PairingConnect =
    Future<void> Function(String host, int port, Duration timeout);

Future<void> _connectAndDiscard(String host, int port, Duration timeout) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  socket.destroy();
}

/// Orders [candidates] for the pairing walk.
///
/// With more than one candidate every address is first probed with a bare TCP
/// connect, all in parallel: the probe cost is the maximum, not the sum, so
/// three black-holed addresses cost one [timeout] instead of three dial budgets.
/// A single candidate skips the probe — the dial itself is the probe.
///
/// Probe winners keep their input order ahead of the losers, and the losers are
/// appended, not dropped: a probe fails fast on one attempt only (a dropped SYN
/// should not evict an address the serial dial could still reach), so they
/// remain as the last-resort tail.
///
/// Within each of those two groups, candidates sharing an IPv4 /24 with one of
/// [localAddresses] come first: that address is the one the network this device
/// is standing on reaches directly, while the others are memories of other
/// networks. Reachability outranks topology — a proven-live address on another
/// subnet is still dialed before an unproven one on this subnet.
Future<List<(String, int)>> orderPairingCandidates(
  List<(String, int)> candidates, {
  required List<LanAddress> localAddresses,
  Duration timeout = kSyncPairingProbeTimeout,
  PairingConnect? connect,
}) async {
  if (candidates.length <= 1) return candidates;
  final probe = connect ?? _connectAndDiscard;
  // Each candidate is classified on its own, and the two groups are then
  // rebuilt in input order — appending from the completion callback would make
  // the order a race the caller cannot see.
  final alive = await Future.wait([
    for (final (host, port) in candidates)
      // `Future.sync` so a probe that throws *synchronously* is classified like
      // any other failed probe instead of aborting the whole round.
      Future<bool>.sync(
        () => probe(host, port, timeout).then((_) => true),
      ).catchError((Object _) => false),
  ]);
  final live = <(String, int)>[];
  final dead = <(String, int)>[];
  for (var i = 0; i < candidates.length; i++) {
    (alive[i] ? live : dead).add(candidates[i]);
  }
  return [
    ..._preferSameSubnet(live, localAddresses),
    ..._preferSameSubnet(dead, localAddresses),
  ];
}

/// Stable partition of [candidates]: the ones sharing an IPv4 /24 with one of
/// [mine] keep their relative order but move ahead of the rest. An empty [mine]
/// leaves the input untouched, which is the state before the first enumeration
/// lands.
List<(String, int)> _preferSameSubnet(
  List<(String, int)> candidates,
  List<LanAddress> mine,
) {
  if (mine.isEmpty || candidates.length <= 1) return candidates;
  final near = <(String, int)>[];
  final far = <(String, int)>[];
  for (final candidate in candidates) {
    final same = mine.any(
      (address) => sameIpv4Subnet(address.address, candidate.$1),
    );
    (same ? near : far).add(candidate);
  }
  return [...near, ...far];
}
