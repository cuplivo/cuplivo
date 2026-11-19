import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_mux.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

Future<void> waitFor(bool Function() condition, {int tries = 100}) async {
  for (var i = 0; i < tries; i += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met in time');
}

void main() {
  late FakeDshTransport transport;
  late DshMux mux;

  DshMuxOptions fastOptions({
    bool autoReconnect = true,
    Duration hostRequestGrace = const Duration(milliseconds: 30),
    Duration readyTimeout = const Duration(seconds: 5),
    int? maxAttempts,
  }) {
    return DshMuxOptions(
      autoReconnect: autoReconnect,
      maxAttempts: maxAttempts,
      readyTimeout: readyTimeout,
      hostRequestGrace: hostRequestGrace,
      retryDelay: (attempt) => Duration.zero,
    );
  }

  setUp(() {
    transport = FakeDshTransport(
      endpoint: DshEndpoint.parse('http://127.0.0.1:3080/?token=t'),
    );
  });

  tearDown(() async {
    await mux.close();
  });

  test(
    'ready handshake defines the generation and opens the event stream first',
    () async {
      mux = DshMux(transport, options: fastOptions());
      final generation = await mux.ready;

      expect(generation.number, 1);
      expect(generation.clientId, 'client-1');
      expect(generation.home, '/home/demo');
      expect(mux.state, DshConnectionState.connected);
      expect(transport.openedEndpoints.first, r'$events');
      final open = transport.sockets.single.sent.first as Map;
      expect(open['type'], 'open');
      expect(open['endpoint'], r'$events');
    },
  );

  test('one stream open frame routes items, end and errors', () async {
    mux = DshMux(transport, options: fastOptions());
    await mux.ready;
    final stream = await mux.open(
      'session/follow',
      args: {
        'request': {
          'address': {'kind': 'session', 'sessionId': 's1'},
        },
      },
    );
    final socket = transport.sockets.single;
    await waitFor(
      () => socket.sent.any(
        (frame) =>
            frame is Map &&
            frame['streamId'] == stream.id &&
            frame['type'] == 'open',
      ),
    );
    final open =
        socket.sent.firstWhere(
              (frame) => frame is Map && frame['streamId'] == stream.id,
            )
            as Map;
    expect(open['endpoint'], 'session/follow');
    expect(open['payload'], {
      'args': {
        'request': {
          'address': {'kind': 'session', 'sessionId': 's1'},
        },
      },
    });

    final items = <Object?>[];
    stream.items.listen(items.add);
    socket.pushItem(stream.id, {'type': 'snapshot'});
    socket.pushEnd(stream.id);
    await waitFor(() => items.length == 1);
    expect(items.single, {'type': 'snapshot'});
  });

  test(
    'stream error becomes a typed RemoteError and closes the stream',
    () async {
      mux = DshMux(transport, options: fastOptions());
      await mux.ready;
      final stream = await mux.open('session/follow');
      final socket = transport.sockets.single;
      final errors = <Object>[];
      stream.items.listen((_) {}, onError: errors.add);
      socket.pushError(stream.id, 'session/not-found', 'No such session');
      await waitFor(() => errors.isNotEmpty);
      expect(errors.single, isA<DshRemoteException>());
      expect((errors.single as DshRemoteException).code, 'session/not-found');
      expect(stream.isClosed, isTrue);
    },
  );

  test(
    'host emits, waterfalls and cancels are forwarded and tracked',
    () async {
      mux = DshMux(transport, options: fastOptions());
      final events = <DshHostEvent>[];
      mux.hostEvents.listen(events.add);
      await mux.ready;
      final socket = transport.sockets.single;
      socket.pushItem('events', {
        'type': 'emit',
        'event': 'api-session/status',
        'args': ['s1', true],
      });
      socket.pushItem('events', {
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'a1',
        'agentId': 's1',
        'request': {'toolName': 'shell'},
      });
      await waitFor(() => events.length == 2);
      expect(events.first, isA<DshHostEmit>());
      expect(mux.pendingRequests, hasLength(1));
      expect(mux.pendingRequests.single.eventId, 'a1');

      socket.pushItem('events', {'type': 'cancel', 'eventId': 'a1'});
      await waitFor(() => events.length == 3);
      expect(events.last, isA<DshHostRequestCancelled>());
      expect(mux.pendingRequests, isEmpty);
    },
  );

  test(
    'a lost socket reopens autoReopen streams on the next generation',
    () async {
      mux = DshMux(transport, options: fastOptions());
      await mux.ready;
      final stream = await mux.open('session/follow', autoReopen: true);
      final items = <Object?>[];
      stream.items.listen(items.add);
      final firstSocket = transport.sockets.single;
      firstSocket.pushItem(stream.id, {'type': 'snapshot', 'cursor': 1});
      await waitFor(() => items.length == 1);

      firstSocket.drop();
      await waitFor(() => transport.sockets.length == 2);
      await waitFor(() => mux.state == DshConnectionState.connected);
      expect(mux.generation!.number, 2);
      final secondSocket = transport.sockets[1];
      secondSocket.pushItem(stream.id, {'type': 'snapshot', 'cursor': 2});
      await waitFor(() => items.length == 2);
      expect(items.last, {'type': 'snapshot', 'cursor': 2});
    },
  );

  test('a non-autoReopen stream fails on generation loss', () async {
    mux = DshMux(transport, options: fastOptions(maxAttempts: 1));
    await mux.ready;
    final stream = await mux.open('workspace/follow', autoReopen: false);
    final errors = <Object>[];
    stream.items.listen((_) {}, onError: errors.add);
    transport.sockets.single.drop();
    await waitFor(() => errors.isNotEmpty);
    expect(errors.single, isA<DshTransportException>());
    expect(stream.isClosed, isTrue);
  });

  test(
    'answerHostRequest uses the generation clientId and settles locally',
    () async {
      transport.values[r'$events/result'] = const {};
      mux = DshMux(transport, options: fastOptions());
      final events = <DshHostEvent>[];
      mux.hostEvents.listen(events.add);
      await mux.ready;
      transport.sockets.single.pushItem('events', {
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'a1',
        'agentId': 's1',
        'request': {'toolName': 'shell'},
      });
      await waitFor(() => mux.pendingRequests.isNotEmpty);

      await mux.answerHostRequest('a1', {
        'kind': 'result',
        'value': 'allowed-once',
      });
      final sent = transport.posted.single;
      expect(sent['endpoint'], r'$events/result');
      expect(sent['payload'], {
        'args': {
          'clientId': 'client-1',
          'eventId': 'a1',
          'outcome': {'kind': 'result', 'value': 'allowed-once'},
        },
      });
      expect(mux.pendingRequests, isEmpty);
      await waitFor(() => events.any((e) => e is DshHostRequestCancelled));
    },
  );

  test(
    'answerHostRequest retries once with the current generation clientId',
    () async {
      transport.values[r'$events/result'] = const {};
      var calls = 0;
      transport.interceptPost = (endpoint, envelope) async {
        if (endpoint != r'$events/result') return null;
        calls += 1;
        if (calls > 1) return null;
        // Simulate the generation changing while the answer is in flight: the
        // Host rejects the old clientId.
        transport.sockets.last.drop();
        for (var i = 0; i < 200; i += 1) {
          if (mux.generation?.number == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return const DshRemoteException(
          'gateway/internal',
          'unknown clientId client-1',
        );
      };
      mux = DshMux(transport, options: fastOptions());
      await mux.ready;
      transport.sockets.single.pushItem('events', {
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': 'a1',
        'agentId': 's1',
        'request': {'toolName': 'shell'},
      });
      await waitFor(() => mux.pendingRequests.isNotEmpty);
      await mux.answerHostRequest('a1', {'kind': 'next'});
      expect(transport.posted, hasLength(2));
      final retried = transport.posted.last;
      expect((retried['payload'] as Map)['args']['clientId'], 'client-2');
    },
  );

  test('an auth rejection makes the mux terminal and unauthorized', () async {
    transport.openMuxFailures.add(
      const DshAuthException('cookie rejected', statusCode: 401),
    );
    mux = DshMux(transport, options: fastOptions());
    await expectLater(mux.ready, throwsA(isA<DshAuthException>()));
    expect(mux.state, DshConnectionState.unauthorized);
    expect(transport.sockets, isEmpty);
  });

  test('ready timeout closes the socket and backs off', () async {
    transport.autoReady = false;
    mux = DshMux(
      transport,
      options: fastOptions(
        autoReconnect: false,
        readyTimeout: const Duration(milliseconds: 20),
      ),
    );
    await expectLater(mux.ready, throwsA(isA<DshTransportException>()));
    await waitFor(() => mux.lastError is DshTransportException);
    expect(mux.state, DshConnectionState.idle);
  });
}
