import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_candidate_prober.dart';
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

void main() {
  group('orderCandidates', () {
    test('a single candidate is returned untouched, without a probe', () async {
      var probed = false;
      final single = [('192.168.1.9', 9527)];

      final ordered = await orderCandidates(
        single,
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
        connect: _probe({'a': true, 'b': false, 'c': true, 'd': false}),
      );

      expect(ordered, [('a', 1), ('c', 3), ('b', 2), ('d', 4)]);
    });

    test('every candidate is probed at once', () async {
      final started = <String>[];
      final gate = Completer<void>();
      final candidates = [('a', 1), ('b', 2), ('c', 3)];

      final pending = orderCandidates(
        candidates,
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
        connect: (host, port, timeout) => throw StateError('probe exploded'),
      );

      expect(ordered, candidates);
    });

    test('with nothing alive the input order is preserved', () async {
      final candidates = [('a', 1), ('b', 2), ('c', 3)];

      final ordered = await orderCandidates(
        candidates,
        connect: _probe(const {}),
      );

      expect(ordered, candidates);
    });

    test('an empty list is returned as-is', () async {
      expect(await orderCandidates(const []), isEmpty);
    });
  });
}
