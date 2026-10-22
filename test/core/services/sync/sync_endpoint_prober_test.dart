import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/services/sync/sync_client.dart';
import 'package:Cuplivo/core/services/sync/sync_endpoint_prober.dart';
import 'package:Cuplivo/core/services/sync/sync_limits.dart';
import 'package:Cuplivo/core/services/sync/sync_local_addresses.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The network order is irrelevant to the probe tests; only the subnet hint is.
const _nowhere = <LanAddress>[];

SyncPeerEndpoint _endpoint(String host, int port) =>
    SyncPeerEndpoint(host: host, port: port);

void main() {
  group('probePeerEndpoints', () {
    test('every endpoint is probed at once and keeps its own answer', () async {
      final started = <String>[];
      final gate = Completer<void>();

      final pending = probePeerEndpoints(
        endpoints: [('a', 1), ('b', 2)],
        probe: (host, port) async {
          started.add(host);
          await gate.future;
          if (host == 'b') throw const SocketException('refused');
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b'], reason: 'the wait is the slowest probe');

      gate.complete();
      final results = await pending;
      expect(results.map((r) => r.host), ['a', 'b']);
      expect(results[0].answered, isTrue);
      expect(results[0].authenticated, isTrue);
      expect(results[0].latency, isNotNull);
      expect(results[1].answered, isFalse);
      expect(results[1].authenticated, isFalse);
      expect(results[1].latency, isNull);
    });

    test('a 401 is an answer: the peer is there, the pairing is not', () async {
      final results = await probePeerEndpoints(
        endpoints: [('a', 1)],
        probe: (host, port) async =>
            throw const SyncClientException('not_paired', statusCode: 401),
      );

      expect(results.single.answered, isTrue);
      expect(results.single.authenticated, isFalse);
      expect(results.single.refusal, SyncRefusalReason.notPaired);
      expect(results.single.noVerdict, isFalse);
    });

    test('a saturated listener is no verdict at all', () async {
      // 503 says the listener is busy, which is a statement about its load, not
      // about the peer: acting on it would darken a live peer's dot.
      final results = await probePeerEndpoints(
        endpoints: [('a', 1)],
        probe: (host, port) async =>
            throw const SyncClientException('ping_busy', statusCode: 503),
      );

      expect(results.single.answered, isFalse);
      expect(results.single.noVerdict, isTrue);
    });

    test('a probe that fails oddly is silence, not an error', () async {
      // A half-open connection surfaces as HttpException; an injected fake can
      // throw anything. Either way it classifies the address — a probe must
      // never abort the round it belongs to.
      final results = await probePeerEndpoints(
        endpoints: [('a', 1), ('b', 2)],
        probe: (host, port) async => throw StateError('probe exploded'),
      );

      expect(results, hasLength(2));
      expect(results.every((r) => !r.answered), isTrue);
    });

    test('a refused handshake is a verdict on the address', () async {
      final results = await probePeerEndpoints(
        endpoints: [('a', 1)],
        probe: (host, port) async =>
            throw const HandshakeException('wrong certificate'),
      );

      expect(results.single.answered, isFalse);
    });

    test('nothing to probe is an empty answer', () async {
      expect(
        await probePeerEndpoints(endpoints: const [], probe: (h, p) async {}),
        isEmpty,
      );
    });

    test('the fan-out never exceeds the concurrency budget', () async {
      // The budget is the listener's own probe cap (see `sync_limits.dart`): a
      // round that asks more questions at once than any listener answers gets
      // `ping_busy` back for the extra, and a `ping_busy` is a *no verdict*, so
      // an unbounded fan-out quietly turns a full address set into "unknown".
      final endpoints = [for (var i = 0; i < 8; i++) ('h$i', 9000 + i)];
      final started = <(String, int)>[];
      var inFlight = 0;
      var peak = 0;

      final results = await probePeerEndpoints(
        endpoints: endpoints,
        maxConcurrent: 3,
        probe: (host, port) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          started.add((host, port));
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
        },
      );

      expect(results, hasLength(endpoints.length));
      expect(
        results.map((r) => r.endpoint),
        unorderedEquals(endpoints),
        reason: 'every endpoint is probed exactly once, choked or not',
      );
      expect(
        started,
        unorderedEquals(endpoints),
        reason: 'the budget postpones a probe, it never drops one',
      );
      expect(
        peak,
        lessThanOrEqualTo(3),
        reason: 'the whole set in flight is what the budget exists to stop',
      );
      expect(
        peak,
        3,
        reason: 'and the chunk is actually full: a serial walk would peak at 1',
      );
    });

    test('two rounds at once share one device-wide budget', () async {
      // The budget has two callers — the periodic tick, which fans out one round
      // per peer *concurrently*, and a session's own fallback round — so a cap on
      // one call bounded nothing: two peers' rounds stacked twice the budget on a
      // listener whose own cap is `kMaxPingsInFlight`, and the overflow answers
      // `ping_busy`, a no-verdict for the addresses the fan-out was grown to
      // support. The pool is the device's budget, not the call's.
      var inFlight = 0;
      var peak = 0;
      Future<void> counted(String host, int port) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
      }

      await Future.wait([
        probePeerEndpoints(
          endpoints: [
            for (var i = 0; i < kSyncProbeConcurrency; i++) ('a$i', 9100 + i),
          ],
          probe: counted,
        ),
        probePeerEndpoints(
          endpoints: [
            for (var i = 0; i < kSyncProbeConcurrency; i++) ('b$i', 9200 + i),
          ],
          probe: counted,
        ),
      ]);

      expect(
        peak,
        lessThanOrEqualTo(kSyncProbeConcurrency),
        reason: 'the device never asks more at once than its listener answers',
      );
      expect(
        peak,
        greaterThan(1),
        reason: 'and it is still parallel: a serial pool is slower, not safer',
      );
    });

    test('the default budget is the listener cap, not a second guess', () {
      // The relationship the two limits have to satisfy, asserted rather than
      // left to a comment: one peer's whole address memory must fit inside what
      // its listener will answer at once.
      expect(
        kSyncProbeConcurrency,
        lessThanOrEqualTo(kMaxPingsInFlight),
        reason: 'a device must never saturate its own listener with one round',
      );
      expect(
        kSyncProbeConcurrency,
        kMaxPeerEndpoints,
        reason: 'the whole set is one wave: the wait stays the slowest probe',
      );
      expect(
        kMaxPingsInFlight,
        greaterThanOrEqualTo(kSyncProbeConcurrency),
        reason:
            'the device never has more than one budget in flight, so its '
            'listener answers a full fan-out with room to spare',
      );
    });
  });

  group('orderCandidatesByProbe', () {
    EndpointProbeResult answered(
      String host,
      int port,
      int ms, {
      bool authenticated = true,
    }) => EndpointProbeResult(
      host: host,
      port: port,
      answered: true,
      authenticated: authenticated,
      latency: Duration(milliseconds: ms),
      measuredAt: DateTime(2026),
    );

    EndpointProbeResult silent(String host, int port) => EndpointProbeResult(
      host: host,
      port: port,
      answered: false,
      authenticated: false,
      measuredAt: DateTime(2026),
    );

    test('the fastest answering address is dialed first', () async {
      final candidates = [('slow', 1), ('fast', 2), ('dead', 3)];
      final ordered = orderCandidatesByProbe(candidates, {
        ('slow', 1): answered('slow', 1, 90),
        ('fast', 2): answered('fast', 2, 4),
        ('dead', 3): silent('dead', 3),
      }, _nowhere);

      expect(ordered, [('fast', 2), ('slow', 1), ('dead', 3)]);
    });

    test('a silent candidate is kept at the tail, never dropped', () async {
      final candidates = [('dead', 1), ('live', 2)];
      final ordered = orderCandidatesByProbe(candidates, {
        ('dead', 1): silent('dead', 1),
        ('live', 2): answered('live', 2, 10),
      }, _nowhere);

      expect(
        ordered.toSet(),
        candidates.toSet(),
        reason:
            'one lost SYN is '
            'not evidence the serial dial could not reach the address',
      );
    });

    test('an unanswered address that never probed counts as silent', () async {
      final ordered = orderCandidatesByProbe(
        [('a', 1), ('b', 2)],
        {('b', 2): answered('b', 2, 8)},
        _nowhere,
      );

      expect(ordered, [('b', 2), ('a', 1)]);
    });

    test('a subnet hint only breaks a latency tie', () async {
      const here = <LanAddress>[(name: 'wlan0', address: '192.168.1.20')];
      final ordered = orderCandidatesByProbe(
        [('10.0.0.7', 1), ('192.168.1.7', 2)],
        {
          ('10.0.0.7', 1): answered('10.0.0.7', 1, 20),
          ('192.168.1.7', 2): answered('192.168.1.7', 2, 20),
        },
        here,
      );

      expect(ordered, [('192.168.1.7', 2), ('10.0.0.7', 1)]);
    });

    test('latency outranks the subnet hint', () async {
      const here = <LanAddress>[(name: 'wlan0', address: '192.168.1.20')];
      final ordered = orderCandidatesByProbe(
        [('10.0.0.7', 1), ('192.168.1.7', 2)],
        {
          ('10.0.0.7', 1): answered('10.0.0.7', 1, 3),
          ('192.168.1.7', 2): answered('192.168.1.7', 2, 60),
        },
        here,
      );

      expect(ordered, [('10.0.0.7', 1), ('192.168.1.7', 2)]);
    });

    test('a single candidate is left alone', () async {
      const single = [('192.168.1.9', 9527)];
      expect(
        orderCandidatesByProbe(single, const {}, _nowhere),
        single,
        reason: 'the dial itself is the probe',
      );
    });
  });

  group('dialableCandidates', () {
    EndpointProbeResult answered(String host, int port, int ms) =>
        EndpointProbeResult(
          host: host,
          port: port,
          answered: true,
          authenticated: true,
          latency: Duration(milliseconds: ms),
          measuredAt: DateTime(2026),
        );

    EndpointProbeResult silent(String host, int port) => EndpointProbeResult(
      host: host,
      port: port,
      answered: false,
      authenticated: false,
      measuredAt: DateTime(2026),
    );

    /// A 503: the listener was too loaded to judge, which is not a verdict.
    EndpointProbeResult busy(String host, int port) => EndpointProbeResult(
      host: host,
      port: port,
      answered: false,
      authenticated: false,
      measuredAt: DateTime(2026),
      errorCode: 'ping_busy',
      noVerdict: true,
    );

    test('only what the probe reached is dialed, best first', () {
      final results = {
        ('dead', 1): silent('dead', 1),
        ('slow', 2): answered('slow', 2, 90),
        ('fast', 3): answered('fast', 3, 4),
      };
      final ordered = orderCandidatesByProbe(
        [('dead', 1), ('slow', 2), ('fast', 3), ('unprobed', 4)],
        results,
        _nowhere,
      );

      expect(dialableCandidates(ordered, results), [
        ('fast', 3),
        ('slow', 2),
      ], reason: 'the dial spends the probe: silent and unprobed buy no dial');
    });

    test('a saturated listener is dialed, not read as a dead address', () {
      final results = {('busy', 1): busy('busy', 1)};
      expect(dialableCandidates([('busy', 1)], results), [('busy', 1)]);
    });

    test('a probe that reached nothing dials nothing', () {
      final results = {
        ('dead', 1): silent('dead', 1),
        ('dead', 2): silent('dead', 2),
      };
      expect(
        dialableCandidates([('dead', 1), ('dead', 2)], results),
        isEmpty,
        reason: 'the caller spends one guess of its own, never a walk',
      );
    });

    test('nothing to choose is nothing to dial', () {
      expect(dialableCandidates(const [], const {}), isEmpty);
    });
  });

  group('selectProbeTargets', () {
    final endpoints = [
      _endpoint('head', 1),
      _endpoint('second', 2),
      _endpoint('third', 3),
      _endpoint('tail-1', 4),
      _endpoint('tail-2', 5),
      _endpoint('tail-3', 6),
    ];

    EndpointProbeResult answered(String host, int ms) => EndpointProbeResult(
      host: host,
      port: endpoints.firstWhere((e) => e.host == host).port,
      answered: true,
      authenticated: true,
      latency: Duration(milliseconds: ms),
      measuredAt: DateTime(2026),
    );

    test('a tick probes the answering addresses, best first', () {
      final previous = {
        ('head', 1): answered('head', 90),
        ('second', 2): answered('second', 5),
        ('third', 3): answered('third', 40),
      };

      expect(selectProbeTargets(endpoints, previous, full: false), [
        ('second', 2),
        ('third', 3),
      ], reason: 'steady state follows what works, capped at the warm count');
    });

    test('nothing has answered yet: the probe looks further down the set', () {
      expect(selectProbeTargets(endpoints, const {}, full: false), [
        ('head', 1),
        ('second', 2),
        ('third', 3),
        ('tail-1', 4),
      ], reason: 'a fresh launch must not stay gray behind a stale head');
    });

    test('a full round covers the tail too', () {
      final previous = {('head', 1): answered('head', 90)};

      expect(selectProbeTargets(endpoints, previous, full: true), [
        ('head', 1),
        ('second', 2),
        ('third', 3),
        ('tail-1', 4),
        ('tail-2', 5),
      ], reason: 'warm first, then the silent tail under its own cap');
    });

    test('a peer with no endpoint probes nothing', () {
      expect(selectProbeTargets(const [], const {}, full: true), isEmpty);
    });

    EndpointProbeResult measured(
      String host,
      int port,
      DateTime at, {
      bool answered = false,
      int? ms,
    }) => EndpointProbeResult(
      host: host,
      port: port,
      answered: answered,
      authenticated: answered,
      latency: ms == null ? null : Duration(milliseconds: ms),
      measuredAt: at,
    );

    test('the tail is asked least recently first', () {
      // Three addresses that answered nothing, measured at three different
      // times: the oldest question is the one worth re-asking.
      final previous = {
        ('head', 1): measured('head', 1, DateTime(2026, 1, 3)),
        ('second', 2): measured('second', 2, DateTime(2026, 1, 1)),
        ('third', 3): measured('third', 3, DateTime(2026, 1, 2)),
      };

      expect(selectProbeTargets(endpoints, previous, full: true), [
        ('tail-1', 4),
        ('tail-2', 5),
        ('tail-3', 6),
        ('second', 2),
      ], reason: 'never-asked addresses lead, then the least recently asked');
    });

    test('three rounds ask every remembered address', () {
      // Twelve endpoints, none of them proved — the state after a peer moves to
      // a network whose address sits behind the history. A fixed first-four
      // would leave eight of them unasked by *any* round, so no measurement
      // would ever prove them and the dial would never try them either.
      final many = [for (var i = 0; i < 12; i++) _endpoint('h$i', 9000 + i)];
      final everProbed = <(String, int)>{};
      var previous = <(String, int), EndpointProbeResult>{};
      for (var round = 0; round < 3; round++) {
        final at = DateTime(2026, 1, 1).add(Duration(minutes: round));
        for (final target in selectProbeTargets(many, previous, full: true)) {
          everProbed.add(target);
          previous[target] = measured(target.$1, target.$2, at);
        }
      }

      expect(
        everProbed.length,
        12,
        reason: 'a rotating tail covers the whole memory in three rounds',
      );
      expect(everProbed, contains(('h5', 9005)));
      expect(everProbed, contains(('h11', 9011)));
    });
  });

  group('dialTimeoutFor', () {
    test('an unmeasured candidate keeps the flat default', () {
      expect(dialTimeoutFor(null), kSyncDialConnectTimeout);
    });

    test('a measured candidate gets a budget derived from its round trip', () {
      final probe = EndpointProbeResult(
        host: 'a',
        port: 1,
        answered: true,
        authenticated: true,
        latency: const Duration(milliseconds: 100),
        measuredAt: DateTime(2026),
      );

      expect(dialTimeoutFor(probe), const Duration(milliseconds: 800));
    });

    test('a very fast answer still gets a budget crypto can meet', () {
      final probe = EndpointProbeResult(
        host: 'a',
        port: 1,
        answered: true,
        authenticated: true,
        latency: const Duration(milliseconds: 1),
        measuredAt: DateTime(2026),
      );

      expect(dialTimeoutFor(probe), const Duration(milliseconds: 500));
    });

    test('a slow answer cannot stretch past the dial default', () {
      final probe = EndpointProbeResult(
        host: 'a',
        port: 1,
        answered: true,
        authenticated: true,
        latency: const Duration(seconds: 4),
        measuredAt: DateTime(2026),
      );

      expect(dialTimeoutFor(probe), kSyncDialConnectTimeout);
    });
  });

  group('SyncPeerEndpoint stats', () {
    test('probes never count as sessions', () {
      final endpoint = _endpoint(
        'a',
        1,
      )..recordProbe(answered: true, latency: const Duration(milliseconds: 12));

      expect(endpoint.successCount, 0);
      expect(endpoint.lastLatencyMs, 12);
      expect(endpoint.addedAt, isNotNull);
    });

    test('a session counts and stamps, and a silence clears the latency', () {
      final endpoint = _endpoint('a', 1)
        ..recordProbe(answered: true, latency: const Duration(milliseconds: 12))
        ..recordSession();

      expect(endpoint.successCount, 1);
      expect(endpoint.lastSuccessAt, isNotNull);

      endpoint.recordProbe(answered: false);
      expect(endpoint.lastLatencyMs, isNull);
    });

    test('a session over a known address keeps its history', () {
      final record = SyncPeerRecord(
        deviceId: 'peer',
        certPem: 'pem',
        secret: 'secret',
        name: 'Peer',
        platform: 'android',
        endpoints: [_endpoint('10.0.0.9', 9527)],
      );
      record.endpoints.single
        ..recordProbe(answered: true, latency: const Duration(milliseconds: 9))
        ..recordSession();

      record.noteEndpointSuccess('10.0.0.9', 9527);

      expect(record.endpoints.single.successCount, 2);
      expect(record.endpoints.single.lastLatencyMs, 9);
    });

    test('deleting one address leaves the others, and the last may go', () {
      final record = SyncPeerRecord(
        deviceId: 'peer',
        certPem: 'pem',
        secret: 'secret',
        name: 'Peer',
        platform: 'android',
        endpoints: [_endpoint('a', 1), _endpoint('b', 2)],
      );

      expect(record.removeEndpoint('a', 1), isTrue);
      expect(record.endpoints.map((e) => e.host), ['b']);
      expect(record.removeEndpoint('b', 2), isTrue);
      expect(record.endpoints, isEmpty);
      expect(record.removeEndpoint('b', 2), isFalse);
    });

    test('repairing one address keeps its counters and the other tiles', () {
      final record = SyncPeerRecord(
        deviceId: 'peer',
        certPem: 'pem',
        secret: 'secret',
        name: 'Peer',
        platform: 'android',
        endpoints: [_endpoint('a', 1), _endpoint('b', 2)],
      );
      record.noteEndpointSuccess('b', 2);
      final repaired = record.endpointFor('b', 2)!
        ..recordProbe(answered: true, latency: const Duration(milliseconds: 9))
        ..recordSession();

      expect(record.editEndpoint('b', 2, 'c', 3), isTrue);

      expect(record.endpoints, hasLength(2));
      expect(
        record.endpointFor('c', 3),
        same(repaired),
        reason: 'the tile is moved, not rebuilt: its history stays with it',
      );
      expect(record.endpoints.first.successCount, 2);
      expect(record.endpoints.first.lastLatencyMs, 9);
      expect(record.endpointFor('b', 2), isNull);
      expect(record.editEndpoint('b', 2, 'c', 3), isFalse);
    });
  });
}
