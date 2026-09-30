import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_candidate_prober.dart';
import 'package:Cuplivo/core/services/sync/sync_local_addresses.dart';
import 'package:flutter_test/flutter_test.dart';

/// A probe that answers from a fixed verdict per host: `true` connects, `false`
/// refuses.
CandidateConnect _probe(Map<String, bool> verdicts, {List<String>? started}) {
  return (host, port, timeout) async {
    started?.add(host);
    if (verdicts[host] ?? false) return;
    throw const SocketException('probe refused');
  };
}

/// The network order is irrelevant to the probe tests; only the subnet hint is.
const _nowhere = <LanAddress>[];

void main() {
  group('orderCandidates', () {
    test('a single candidate is returned untouched, without a probe', () async {
      var probed = false;
      final single = [('192.168.1.9', 9527)];

      final ordered = await orderCandidates(
        single,
        localAddresses: _nowhere,
        connect: (host, port, timeout) async {
          probed = true;
        },
      );

      expect(ordered, single);
      expect(probed, isFalse, reason: 'the dial itself is the probe');
    });

    test('winners keep their order ahead of the losers', () async {
      final candidates = [('a', 1), ('b', 2), ('c', 3), ('d', 4)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: _nowhere,
        connect: _probe({'a': true, 'b': false, 'c': true, 'd': false}),
      );

      expect(ordered, [('a', 1), ('c', 3), ('b', 2), ('d', 4)]);
    });

    test('a winner that answers before another keeps its input rank', () async {
      // The probes finish out of input order, which is the ordinary case: two
      // live addresses at different latencies. While the answer's arrival
      // decided the order, the same set could be ordered differently on
      // consecutive rounds — and this order is what a peer's record stores as
      // hints and what the serial dial follows.
      final gates = {'slow': Completer<void>(), 'fast': Completer<void>()};
      final pending = orderCandidates(
        [('slow', 1), ('fast', 2), ('gone', 3)],
        localAddresses: _nowhere,
        connect: (host, port, timeout) => gates[host]!.future,
      );

      gates['fast']!.complete();
      gates['slow']!.complete();

      expect(await pending, [('slow', 1), ('fast', 2), ('gone', 3)]);
    });

    test('every candidate is probed at once', () async {
      final started = <String>[];
      final gate = Completer<void>();
      final candidates = [('a', 1), ('b', 2), ('c', 3)];

      final pending = orderCandidates(
        candidates,
        localAddresses: _nowhere,
        connect: (host, port, timeout) async {
          started.add(host);
          await gate.future;
        },
      );
      // Nothing has finished, so a serial probe would have started only the
      // first candidate by now. This is the assertion that the cost is the
      // maximum and not the sum.
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b', 'c']);

      gate.complete();
      expect(await pending, candidates);
    });

    test('a candidate that never answers falls to the tail, not out', () async {
      final candidates = [('dead', 1), ('live', 2), ('also-dead', 3)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: _nowhere,
        connect: _probe({'live': true}),
      );

      expect(ordered, [('live', 2), ('dead', 1), ('also-dead', 3)]);
      expect(
        ordered.toSet(),
        candidates.toSet(),
        reason: 'a lost SYN must not evict an address the dial could reach',
      );
    });

    test('a probe failure never escapes as an error', () async {
      final candidates = [('a', 1), ('b', 2)];

      // Not a SocketException: even an unexpected failure has to classify the
      // address rather than abort the whole round.
      final ordered = await orderCandidates(
        candidates,
        localAddresses: _nowhere,
        connect: (host, port, timeout) => throw StateError('probe exploded'),
      );

      expect(ordered, candidates);
    });

    test('with nothing alive the input order is preserved', () async {
      final candidates = [('a', 1), ('b', 2), ('c', 3)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: _nowhere,
        connect: _probe(const {}),
      );

      expect(ordered, candidates);
    });

    test('an empty list is returned as-is', () async {
      expect(
        await orderCandidates(const [], localAddresses: _nowhere),
        isEmpty,
      );
    });
  });

  group('orderCandidates, subnet preference', () {
    // The address this device holds: 192.168.1.0/24 is "here", 10.20.30.0/24 is
    // a memory of another network.
    const here = <LanAddress>[(name: 'wlan0', address: '192.168.1.20')];

    test('an address on this device own subnet is dialed first', () async {
      final candidates = [('10.20.30.40', 1), ('192.168.1.7', 2)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: here,
        connect: _probe({'10.20.30.40': true, '192.168.1.7': true}),
      );

      expect(ordered, [('192.168.1.7', 2), ('10.20.30.40', 1)]);
    });

    test('reachability outranks the subnet hint', () async {
      // The same-subnet candidate did not answer, so it may not jump a winner.
      final candidates = [('192.168.1.7', 1), ('10.20.30.40', 2)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: here,
        connect: _probe({'10.20.30.40': true}),
      );

      expect(ordered, [('10.20.30.40', 2), ('192.168.1.7', 1)]);
    });

    test('a same-subnet loser is ordered before a far loser', () async {
      final candidates = [('10.20.30.40', 1), ('192.168.1.7', 2)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: here,
        connect: _probe(const {}),
      );

      expect(ordered, [('192.168.1.7', 2), ('10.20.30.40', 1)]);
    });

    test('without local addresses the probe order stands', () async {
      final candidates = [('10.20.30.40', 1), ('192.168.1.7', 2)];

      final ordered = await orderCandidates(
        candidates,
        localAddresses: _nowhere,
        connect: _probe({'10.20.30.40': true, '192.168.1.7': true}),
      );

      expect(ordered, candidates);
    });
  });
}
