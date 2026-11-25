import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/dsh/dsh_client.dart';
import 'package:Cuplivo/core/dsh/dsh_errors.dart';
import 'package:Cuplivo/core/dsh/dsh_events.dart';
import 'package:Cuplivo/core/dsh/dsh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dsh_fakes.dart';

Map<String, Object?> _catalogValues() =>
    (jsonDecode(
              File(
                'test/core/dsh/fixtures/catalog_values.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

List<Object?> _followValues() =>
    File('test/core/dsh/fixtures/follow_frames.jsonl')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => (jsonDecode(line) as Map)['value'])
        .toList(growable: false);

void main() {
  late Map<String, Object?> catalog;
  late Map<String, Object?> snapshot;

  setUp(() {
    catalog = _catalogValues();
    snapshot = (_followValues().first as Map).cast<String, Object?>();
  });

  /// Answers login/verify/JSON-RPC and builds a mux socket that greets with
  /// ready plus the opening frames the catalog/session need.
  FakeDshHttpClient buildHttp() {
    final http = FakeDshHttpClient();
    http.onUpgrade = (request) {
      final socket = FakeDshSocket();
      socket.onSend = (frame) {
        if (frame is! Map || frame['type'] != 'open') return;
        final streamId = '${frame['streamId']}';
        final endpoint = frame['endpoint'];
        if (endpoint == r'$events') {
          socket.pushItem(streamId, {
            'type': 'ready',
            'clientId': 'client-1',
            'host': {'home': '/home/demo'},
          });
        } else if (endpoint == 'workspace/follow') {
          socket.pushItem(streamId, catalog['workspace/follow']);
        } else if (endpoint == 'session/follow') {
          socket.pushItem(streamId, snapshot);
        }
      };
      return socket;
    };
    http.handler = (request) async {
      if (request.method == 'GET' && request.uri.path == '/') {
        if (request.uri.queryParameters.containsKey('token')) {
          return const DshHttpResponse(
            statusCode: 303,
            headers: {'location': './'},
            setCookie: [
              'dsh-auth-hash=v1.a.b; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict',
            ],
            body: '',
          );
        }
        return const DshHttpResponse(
          statusCode: 200,
          headers: {'content-type': 'text/html'},
          setCookie: [],
          body: '<html></html>',
        );
      }
      if (request.method == 'POST' && request.uri.path.startsWith('/api/')) {
        final endpoint = request.uri.path.substring('/api/'.length);
        final envelope = (jsonDecode(utf8.decode(request.body!)) as Map)
            .cast<String, Object?>();
        final value = catalog[endpoint];
        if (value == null) {
          return const DshHttpResponse(
            statusCode: 404,
            headers: {},
            setCookie: [],
            body: '{"error":"not found"}',
          );
        }
        return DshHttpResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          setCookie: const [],
          body: jsonEncode({
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {'ok': true, 'value': value},
          }),
        );
      }
      return const DshHttpResponse(
        statusCode: 404,
        headers: {},
        setCookie: [],
        body: '',
      );
    };
    return http;
  }

  test(
    'pair() logs in, verifies, connects and drops the launch token',
    () async {
      final http = buildHttp();
      final client = await DshClient.pair(
        'dsh web: http://127.0.0.1:3080/?token=launch-token',
        httpClient: http,
      );
      addTearDown(client.close);

      expect(client.cookie, isNotNull);
      expect(client.cookie!.authority, '127.0.0.1:3080');
      expect(client.endpoint.token, isNull, reason: 'token is not retained');
      expect(client.state, DshConnectionState.connected);
      expect(client.mux.generation!.clientId, 'client-1');

      final login = http.requests.first;
      expect(login.uri.queryParameters['token'], 'launch-token');
      expect(login.authority, '127.0.0.1:3080');
      expect(login.headers['origin'], isNull);
      final verify = http.requests[1];
      expect(verify.method, 'GET');
      expect(verify.uri.path, '/');
      expect(verify.headers['cookie'], 'dsh-auth-hash=v1.a.b');
    },
  );

  test('pair() resumes with a stored cookie and no token', () async {
    final http = buildHttp();
    final cookie = const DshCookie(
      name: 'dsh-auth-hash',
      value: 'v1.stored.sig',
      authority: '127.0.0.1:3080',
    );
    final client = await DshClient.pair(
      'http://127.0.0.1:3080',
      storedCookie: cookie,
      httpClient: http,
    );
    addTearDown(client.close);
    expect(client.endpoint.hasToken, isFalse);
    expect(client.cookie!.value, 'v1.stored.sig');
    expect(client.state, DshConnectionState.connected);
    expect(http.requests.first.uri.queryParameters, isEmpty);
  });

  test('pair() refuses a URL with neither token nor stored cookie', () async {
    final http = buildHttp();
    await expectLater(
      DshClient.pair('http://127.0.0.1:3080', httpClient: http),
      throwsA(isA<DshAuthException>()),
    );
  });

  test('loadCatalog reads the batch and keeps the last snapshot', () async {
    final http = buildHttp();
    final client = await DshClient.pair(
      'http://127.0.0.1:3080/?token=t',
      httpClient: http,
    );
    addTearDown(client.close);
    final snapshot = await client.loadCatalog();
    expect(snapshot.sessions, hasLength(2));
    expect(snapshot.workspaces.single.title, 'Demo');
    expect(client.catalogSnapshot, same(snapshot));
    expect(client.catalog.capabilities.supports('session/list'), isTrue);
  });

  test('openSession caches handles; store follows the session', () async {
    final http = buildHttp();
    final client = await DshClient.pair(
      'http://127.0.0.1:3080/?token=t',
      httpClient: http,
    );
    addTearDown(client.close);
    final id = 'session-7f3c2a9e-0000-4000-8000-000000000001';
    expect(client.openSession(id), same(client.openSession(id)));

    final store = await client.store(id);
    addTearDown(store.dispose);
    expect(store.transcript.snapshot, isNotNull);
    expect(store.transcript.permissionPreset, 'workspace-write');
    expect(store.transcript.header!.id, id);
  });

  test('an invalid pasted URL fails fast', () async {
    await expectLater(
      DshClient.pair('ftp://example.test/x'),
      throwsA(isA<DshEndpointException>()),
    );
  });
}
