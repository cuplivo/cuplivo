import 'package:Cuplivo/core/dsh/dsh_endpoint.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_rpc.dart';
import 'package:Cuplivo/core/dsh/dsh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

void main() {
  late FakeDshTransport transport;
  late DshRpc rpc;

  setUp(() {
    transport = FakeDshTransport(
      endpoint: DshEndpoint.parse('http://127.0.0.1:3080/?token=t'),
    );
    rpc = DshRpc(transport);
  });

  test(
    'sends the client-request envelope and returns the business value',
    () async {
      transport.values['session/list'] = {
        'items': [
          {'sessionId': 's1', 'updatedAt': 1},
        ],
      };
      final value = await rpc.call(
        'session/list',
        args: {'_request': <String, Object?>{}},
      );
      expect(value, isA<Map>());

      final sent = transport.posted.single;
      expect(sent['endpoint'], 'session/list');
      expect(sent['type'], 'client-request');
      expect(sent['method'], 'session/list');
      expect(sent['rpcId'], isA<String>());
      expect(sent['payload'], {
        'args': {'_request': <String, Object?>{}},
      });
    },
  );

  test(
    'ok:false becomes a DshRemoteException carrying code and details',
    () async {
      transport.remoteErrors['session/follow'] = const DshRemoteException(
        'session/not-found',
        'No such session',
        {'sessionId': 'gone'},
      );
      await expectLater(
        rpc.call('session/follow'),
        throwsA(
          isA<DshRemoteException>()
              .having((e) => e.code, 'code', 'session/not-found')
              .having((e) => e.details['sessionId'], 'details', 'gone'),
        ),
      );
    },
  );

  test('a 404 is an unsupported capability, not a business error', () async {
    transport.statuses['workspace/follow'] = 404;
    await expectLater(
      rpc.call('workspace/follow'),
      throwsA(isA<DshUnsupportedException>()),
    );
  });

  test(
    'a 401 is an auth failure and a 5xx a retryable transport error',
    () async {
      transport.statuses['session/list'] = 401;
      await expectLater(
        rpc.call('session/list'),
        throwsA(isA<DshAuthException>()),
      );
      transport.statuses['session/list'] = 503;
      await expectLater(
        rpc.call('session/list'),
        throwsA(
          isA<DshTransportException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    },
  );

  test('idempotent calls retry once on a transport failure', () async {
    transport.values['session/list'] = {'items': []};
    transport.transportFailures['session/list'] = 1;
    final value = await rpc.call('session/list', idempotent: true);
    expect(value, {'items': []});
    expect(transport.posted, hasLength(2));
  });

  test('non-idempotent calls never retry', () async {
    transport.values['session/prompt'] = {'accepted': true};
    transport.transportFailures['session/prompt'] = 1;
    await expectLater(
      rpc.call('session/prompt'),
      throwsA(isA<DshTransportException>()),
    );
    expect(transport.posted, hasLength(1));
  });

  test('rejects a mismatched rpcId', () async {
    transport.values['session/list'] = {'items': []};
    // Hand-craft a wrong rpcId by intercepting the transport response.
    final fake = _WrongIdTransport(transport);
    final wrong = DshRpc(fake);
    await expectLater(
      wrong.call('session/list'),
      throwsA(isA<DshProtocolException>()),
    );
  });
}

/// Answers every endpoint with a response whose rpcId does not match.
class _WrongIdTransport extends FakeDshTransport {
  _WrongIdTransport(FakeDshTransport inner) : super(endpoint: inner.endpoint);

  @override
  Future<DshHttpResponse> post(String endpoint, Object? envelope) async {
    return const DshHttpResponse(
      statusCode: 200,
      headers: {'content-type': 'application/json'},
      setCookie: [],
      body:
          '{"type":"server-response","rpcId":"someone-else",'
          '"result":{"ok":true,"value":{}}}',
    );
  }
}
