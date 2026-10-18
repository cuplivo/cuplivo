import 'dart:async';
import 'dart:io';

import 'sync_client.dart';
import 'sync_local_addresses.dart';
import 'sync_models.dart';
import 'sync_store.dart';

/// How long a probe answer stays usable as the dial's pre-step. A round that
/// landed just now is what the next session orders its candidates by; an older
/// one describes a network this device may have already left, so the session
/// probes again.
const Duration kSyncProbeFreshness = Duration(seconds: 15);

/// How many answering endpoints the periodic tick keeps probing. The tail is
/// only probed when these all go silent (or on a full round), which is what
/// lets the endpoint cap be generous without making the tick expensive.
const int kSyncWarmEndpointCount = 2;

/// How many silent endpoints a full round probes looking for a live one.
const int kSyncTailProbeCount = 4;

/// One endpoint's answer to an authenticated probe.
///
/// Two booleans, not one, because they are different facts with different
/// repairs: [answered] is "something at this address replied" (the peer is
/// there — a refusal counts), [authenticated] is "…and it accepted this
/// device's pairing secret" (this address can carry a session). A recycled
/// lease answers without authenticating; a peer that was reset elsewhere
/// authenticates nowhere. The online dot reads the first, the dial reads the
/// second.
class EndpointProbeResult {
  const EndpointProbeResult({
    required this.host,
    required this.port,
    required this.answered,
    required this.authenticated,
    required this.measuredAt,
    this.latency,
    this.errorCode,
    this.refusal,
    this.noVerdict = false,
  });

  final String host;
  final int port;

  /// Something answered at this address (a 401 is an answer).
  final bool answered;

  /// …and it answered as this paired device, accepting our secret.
  final bool authenticated;

  final DateTime measuredAt;

  /// Round trip of the answered probe, measured by the caller. Null when
  /// nothing answered.
  final Duration? latency;

  /// Transport-level code for a failure (`ping_busy`, `not_paired`, …).
  final String? errorCode;

  /// The pairing refusal this probe read, when the peer answered as itself but
  /// refused this device.
  final SyncRefusalReason? refusal;

  /// The probe learned nothing about the peer — the listener is saturated, so
  /// the answer is about its load, not about it. The caller keeps whatever it
  /// already knew instead of painting the peer offline.
  final bool noVerdict;

  (String, int) get endpoint => (host, port);
}

/// The one probe call, injectable so tests can manufacture winners, losers and
/// timings without real sockets or certificates.
typedef EndpointProbeFn = Future<void> Function(String host, int port);

/// Builds the production probe: one pinned TLS connection and one authenticated
/// request against [host]:[port].
///
/// A fresh client per attempt is deliberate — a pooled connection would report
/// an idle socket's health instead of the address's, and tearing it down is
/// what keeps a stale address from looking warm.
EndpointProbeFn syncEndpointProbe(
  SyncClient client,
  SyncPeerRecord peer, {
  Duration timeout = kSyncPingDeadline,
}) {
  return (host, port) async {
    final session = client.openSession(
      peer,
      host: host,
      port: port,
      pingDeadline: timeout,
    );
    try {
      await session.ping();
    } finally {
      session.close();
    }
  };
}

/// Probes every endpoint of one peer at once and reports each one separately.
///
/// The wait is the slowest probe, not their sum, and each endpoint keeps its
/// own answer: collapsing N endpoints into one boolean is what made the panel
/// able to show only "one of these works", with no latency and no way to tell a
/// dead address from a slow one.
///
/// A probe classifies the address *and* the pairing, because it is an
/// authenticated request: whatever answers is pinned to the peer's certificate
/// inside the handshake, so a wrong device fails the pin before a byte of
/// request leaves here.
Future<List<EndpointProbeResult>> probePeerEndpoints({
  required List<(String, int)> endpoints,
  required EndpointProbeFn probe,
  DateTime Function()? now,
}) async {
  if (endpoints.isEmpty) return const [];
  final clock = now ?? DateTime.now;
  return Future.wait([
    for (final (host, port) in endpoints) _probeOne(probe, host, port, clock),
  ]);
}

Future<EndpointProbeResult> _probeOne(
  EndpointProbeFn probe,
  String host,
  int port,
  DateTime Function() clock,
) async {
  final watch = Stopwatch()..start();
  try {
    await probe(host, port);
    watch.stop();
    return EndpointProbeResult(
      host: host,
      port: port,
      answered: true,
      authenticated: true,
      latency: watch.elapsed,
      measuredAt: clock(),
    );
  } on SyncClientException catch (error) {
    watch.stop();
    // `ping_busy` is the listener saying "not now" — that is about its load,
    // not about this address, so it must not overwrite a working verdict.
    if (error.message == 'ping_busy') {
      return EndpointProbeResult(
        host: host,
        port: port,
        answered: false,
        authenticated: false,
        measuredAt: clock(),
        errorCode: error.message,
        noVerdict: true,
      );
    }
    final refused = error.message == 'not_paired';
    return EndpointProbeResult(
      host: host,
      port: port,
      // A 401 came *from* the peer: it is there, it just does not recognise
      // this pairing any more. That is the strongest kind of "online".
      answered: true,
      authenticated: false,
      measuredAt: clock(),
      latency: refused ? watch.elapsed : null,
      errorCode: error.message,
      refusal: refused ? SyncRefusalReason.notPaired : null,
    );
  } on TimeoutException {
    watch.stop();
    return _silent(host, port, clock);
  } on TlsException {
    // `HandshakeException` included: the pin refused the certificate this
    // address presented, so nothing at all answered *as this peer*. The walk
    // moves on to the next address.
    watch.stop();
    return _silent(host, port, clock);
  } on SocketException {
    watch.stop();
    return _silent(host, port, clock);
  } catch (_) {
    // A probe classifies an address; it never aborts the round it belongs to.
    // That covers the shapes a half-open connection produces (`HttpException`
    // when the peer closes before the status line) as well as anything
    // unexpected — a probe that failed oddly is still a probe that did not
    // answer.
    watch.stop();
    return _silent(host, port, clock);
  }
}

EndpointProbeResult _silent(String host, int port, DateTime Function() clock) =>
    EndpointProbeResult(
      host: host,
      port: port,
      answered: false,
      authenticated: false,
      measuredAt: clock(),
    );

/// The endpoints a periodic tick should probe.
///
/// [warm] are the endpoints that answered last round, best first. A tick
/// probes those only: the cap is twelve endpoints, but steady-state traffic
/// should follow the addresses that work, not the memory of networks this
/// device has left. [full] probes the silent tail too, up to
/// [kSyncTailProbeCount] of them, and is what every evidence-changing moment
/// uses (start, resume, panel open, after a session, after pairing).
List<(String, int)> selectProbeTargets(
  List<SyncPeerEndpoint> endpoints,
  Map<(String, int), EndpointProbeResult> previous, {
  required bool full,
}) {
  if (endpoints.isEmpty) return const [];
  final labelled = [
    for (final endpoint in endpoints)
      (endpoint: endpoint, key: (endpoint.host, endpoint.port)),
  ];
  final warm =
      [
        for (final item in labelled)
          if (previous[item.key]?.answered ?? false) item,
      ]..sort((a, b) {
        final left = previous[a.key]?.latency ?? const Duration(days: 1);
        final right = previous[b.key]?.latency ?? const Duration(days: 1);
        return left.compareTo(right);
      });
  final cold = [
    for (final item in labelled)
      if (!(previous[item.key]?.answered ?? false)) item,
  ];
  if (!full) {
    if (warm.isNotEmpty) {
      return [for (final item in warm.take(kSyncWarmEndpointCount)) item.key];
    }
    // Nothing has answered yet (a fresh launch, a new pairing, a network
    // change): look further than the tick normally would, or a peer whose
    // remembered head is stale would stay gray until a full round happens.
    return [for (final item in cold.take(kSyncTailProbeCount)) item.key];
  }
  return [
    for (final item in warm) item.key,
    for (final item in cold.take(kSyncTailProbeCount)) item.key,
  ];
}

/// Orders [candidates] for the dial from what the probes measured.
///
/// Answered endpoints first, fastest first — the address that answered in 4 ms
/// is the one to dial, and the measured round trip is also what bounds its
/// connect timeout. Silent ones are kept behind them rather than dropped: the
/// order is what [dialableCandidates] preserves when it decides which of these
/// addresses is worth a session, and the one unproved candidate a dial still
/// spends when the probe proved none at all is read off this head.
///
/// The measured latency outranks topology; [localAddresses] only breaks a tie
/// between two answered endpoints, where an address on the network this device
/// is standing on is still the better bet than a memory of another one.
List<(String, int)> orderCandidatesByProbe(
  List<(String, int)> candidates,
  Map<(String, int), EndpointProbeResult> results,
  List<LanAddress> localAddresses,
) {
  if (candidates.length <= 1) return candidates;
  final answered = <(String, int)>[];
  final silent = <(String, int)>[];
  for (final candidate in candidates) {
    ((results[candidate]?.answered ?? false) ? answered : silent).add(
      candidate,
    );
  }
  answered.sort((a, b) {
    final left = results[a]?.latency ?? const Duration(days: 1);
    final right = results[b]?.latency ?? const Duration(days: 1);
    final byLatency = left.compareTo(right);
    if (byLatency != 0) return byLatency;
    final leftNear = _isOnMyNetwork(a.$1, localAddresses);
    final rightNear = _isOnMyNetwork(b.$1, localAddresses);
    if (leftNear == rightNear) return 0;
    return leftNear ? -1 : 1;
  });
  return [...answered, ...silent];
}

/// The candidates the probe proved fit to carry a session, in [ordered] order.
///
/// `answered` is the proof: something at that address completed a pinned TLS
/// handshake and answered an authenticated request, which is exactly what a
/// session needs. A `noVerdict` (a 503 from a saturated listener) counts too —
/// it says the listener was too busy to judge, so reading it as a refusal
/// would turn the peer's load into a verdict about the address.
///
/// Everything else is left out, because the probe is the dial's *parallel*
/// pre-step: it already asked every address at once. Walking the silent ones
/// one at a time would re-ask, serially, a question that was just answered in
/// parallel, and pay a full connect budget for each repetition.
List<(String, int)> dialableCandidates(
  List<(String, int)> ordered,
  Map<(String, int), EndpointProbeResult> results,
) {
  return [
    for (final candidate in ordered)
      if (results[candidate]?.answered == true ||
          results[candidate]?.noVerdict == true)
        candidate,
  ];
}

bool _isOnMyNetwork(String host, List<LanAddress> mine) =>
    mine.any((address) => sameIpv4Subnet(address.address, host));

/// The connect timeout for one candidate, derived from what it just measured.
///
/// A LAN host that answers a probe in 4 ms and then does not complete a
/// handshake within a second is not slow — it is gone, and waiting the flat
/// three seconds only makes the walk slower. The budget is a small multiple of
/// the measured round trip (enough for the handshake that follows the TCP
/// connect), clamped so a very fast answer still gets a budget crypto can meet
/// and a slow one cannot stretch past the dial's own default.
Duration dialTimeoutFor(
  EndpointProbeResult? probe, {
  Duration fallback = kSyncDialConnectTimeout,
}) {
  final latency = probe?.latency;
  if (latency == null) return fallback;
  final derived = latency * 8;
  const floor = Duration(milliseconds: 500);
  if (derived < floor) return floor;
  if (derived > fallback) return fallback;
  return derived;
}
