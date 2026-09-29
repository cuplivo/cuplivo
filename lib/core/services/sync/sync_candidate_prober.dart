import 'dart:async';
import 'dart:io';

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
/// A probe failure classifies the address, never the peer: whatever answers
/// is still pinned by its certificate at dial time.
Future<List<(String, int)>> orderCandidates(
  List<(String, int)> candidates, {
  Duration timeout = kSyncProbeTimeout,
  CandidateConnect? connect,
}) async {
  if (candidates.length <= 1) return candidates;
  final probe = connect ?? _connectAndDiscard;
  final live = <(String, int)>[];
  final dead = <(String, int)>[];
  await Future.wait([
    for (final (host, port) in candidates)
      // `Future.sync` so a probe that throws *synchronously* is classified
      // like any other failed probe instead of aborting the whole round.
      Future<void>.sync(() => probe(host, port, timeout))
          .then((_) => live.add((host, port)))
          .catchError((Object _) => dead.add((host, port))),
  ]);
  return [...live, ...dead];
}
