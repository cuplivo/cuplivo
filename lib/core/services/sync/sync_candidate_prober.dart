import 'dart:async';
import 'dart:io';

import 'sync_local_addresses.dart';

/// Budget for one bare-TCP candidate probe. A live LAN host answers a SYN in
/// milliseconds, so two seconds covers one lost packet plus its retransmit;
/// anything slower is not slow, it is gone.
const Duration kSyncProbeTimeout = Duration(seconds: 2);

/// One probe attempt, injectable so tests can manufacture winners and losers
/// without real sockets. The default connects and immediately discards the
/// socket: a probe tests the *address*, never the peer — identity is still
/// decided by the TLS pin when the real dial happens.
typedef CandidateConnect =
    Future<void> Function(String host, int port, Duration timeout);

Future<void> _connectAndDiscard(String host, int port, Duration timeout) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  socket.destroy();
}

/// Whether *any* of [endpoints] answers a bare TCP connect — the panel's
/// online dot. Same probe, same budget, same "a probe tests the address, never
/// the peer" contract as [orderCandidates]; empty input is simply offline.
Future<bool> anyEndpointReachable(
  List<(String, int)> endpoints, {
  Duration timeout = kSyncProbeTimeout,
  CandidateConnect? connect,
}) async {
  if (endpoints.isEmpty) return false;
  final probe = connect ?? _connectAndDiscard;
  final answers = await Future.wait([
    for (final (host, port) in endpoints)
      Future<bool>.sync(
        () => probe(host, port, timeout).then((_) => true),
      ).catchError((Object _) => false),
  ]);
  return answers.any((answered) => answered);
}

/// Orders [candidates] for a serial dial.
///
/// With more than one candidate every address is first probed with a bare TCP
/// connect, all in parallel: the probe cost is the maximum, not the sum, so
/// three black-holed addresses cost one [timeout] instead of three dial
/// budgets. A single candidate skips the probe — the dial itself is the probe.
///
/// Probe winners keep their input order ahead of the losers, and the losers
/// are appended, not dropped: a probe fails fast on one attempt only (a
/// dropped SYN should not evict an address the serial dial could still
/// reach), so they remain as the last-resort tail.
///
/// The order is a property of the list, never of who answered first: a winner
/// that answers later still keeps its rank, because the same set of addresses
/// has to produce the same order on every round — that order is what the
/// pairing record stores as hints and what the serial dial follows.
///
/// Within each of those two groups, candidates sharing an IPv4 /24 with one of
/// [localAddresses] come first: that address is the one the network this device
/// is standing on reaches directly, while the others are memories of other
/// networks. Reachability outranks topology — a proven-live address on another
/// subnet is still dialed before an unproven one on this subnet.
///
/// A probe failure classifies the address, never the peer: whatever answers
/// is still pinned by its certificate at dial time.
Future<List<(String, int)>> orderCandidates(
  List<(String, int)> candidates, {
  required List<LanAddress> localAddresses,
  Duration timeout = kSyncProbeTimeout,
  CandidateConnect? connect,
}) async {
  if (candidates.length <= 1) return candidates;
  final probe = connect ?? _connectAndDiscard;
  // Each candidate is classified on its own, and the two groups are then
  // rebuilt in input order — appending from the completion callback would make
  // the order a race the caller cannot see.
  final alive = await Future.wait([
    for (final (host, port) in candidates)
      // `Future.sync` so a probe that throws *synchronously* is classified
      // like any other failed probe instead of aborting the whole round.
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
